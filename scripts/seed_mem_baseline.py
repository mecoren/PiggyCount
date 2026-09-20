# -*- coding: utf-8 -*-
"""
PiggyCount 内存基线语料注入（B6）
=================================
往**一个已存在的库文件**里灌三档数据集，供 scripts/profile_memory.py 在真机上量：

  S   500 笔 /   2 附件   快速回归（纯 SQL + 2 张图，跑得起）
  M 10000 笔 / 200 附件   主基线档 —— 方案里"1 万条交易 + 200 附件"那一条
  L 100000 笔 / 800 附件  nightly / 手动，只在复现大账本问题（M2 首页全量、M13 归档）时用

用法:
  python scripts/seed_mem_baseline.py --tier M --db scripts/live_db/live_16384.sqlite
  # 附件物理文件落在 --attachments-dir，再按最后打印的那两条 adb 命令推到设备

约定（全部从当前库里读，不新造实体）:
  * 目标账本默认取**交易最多**的那个（--ledger-id 可指定）。单账本体量才是首页/报表的内存路径。
  * 只写 transactions / transaction_attachments，不新建账本/账户/分类：新实体走 sync 的
    "本地独有"分支，测基线时容易被云端反向清掉，所以要测就测已存在的账本。
  * happened_at / created_at 单位是**秒**（本库 drift 把 DateTime 存成秒：插
    2026-09-19T12:00Z 回读 1789819200，实测记在 §13 B6）。
  * 幂等：按"该账本现有交易数"补齐到目标条数，附件按"现有行数"补齐，可反复跑。
  * 附件行沿用应用自己的命名 sha_<sha256>.jpg + 真实 local_sha256（读图路径按文件名找文件）。
  * 合成图是**近似纯色** JPEG（几十 KB）：附件的内存代价在**解码后**（1920×1920×4B=14.7MB/张，
    见 lib/services/attachment_service.dart:20-21），与文件体积无关。要真实体积（M13 归档
    峰值 ≈ 附件总量 ×3）时加 --from-photos <目录>，脚本原样复制而不生成。
"""
import argparse
import hashlib
import os
import random
import shutil
import sqlite3
import sys
import time
import uuid

# 重定向到文件时的中文日志（Windows 默认 GBK，日志文件会读成乱码）
sys.stdout.reconfigure(encoding='utf-8')
sys.stderr.reconfigure(encoding='utf-8')

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import inject_transactions as itx  # 复用同一套类型权重/金额区间/汇率折算

TIERS = {'S': (500, 2), 'M': (10000, 200), 'L': (100000, 800)}
SPREAD_DAYS = int(3 * 365.25)  # 与 inject_transactions 一致：摊到最近三年
TX_CHUNK = 5000


def pick_ledger(cur, wanted):
    if wanted:
        row = cur.execute("SELECT id FROM ledgers WHERE id=?", (wanted,)).fetchone()
        if not row:
            sys.exit(f'账本 id={wanted} 不存在')
        return wanted
    row = cur.execute(
        "SELECT l.id, l.name, COUNT(t.id) FROM ledgers l "
        "LEFT JOIN transactions t ON t.ledger_id=l.id "
        "GROUP BY l.id ORDER BY COUNT(t.id) DESC, l.id LIMIT 1").fetchone()
    if not row:
        sys.exit('库里没有账本')
    print(f'目标账本: id={row[0]} {row[1]} 现有 {row[2]} 笔')
    return row[0]


def seed_tx(cur, con, ledger_id, owner_uid, target, seed):
    rng = random.Random(seed)
    expense_cats, income_cats, transfer_cats = itx.fetch_categories(cur)
    transfer_cat = transfer_cats[0] if transfer_cats else None
    accs = cur.execute(
        "SELECT id, currency FROM accounts WHERE ledger_id=?", (ledger_id,)).fetchall()
    if not accs:
        sys.exit(f'账本 {ledger_id} 下没有账户：交易要挂账户，请先在应用里建一个')
    acc_ids = [a[0] for a in accs]
    acc_ccy = dict(accs)

    existing = cur.execute(
        "SELECT COUNT(*) FROM transactions WHERE ledger_id=?", (ledger_id,)).fetchone()[0]
    need = target - existing
    if need <= 0:
        print(f'交易已够: {existing}/{target}，跳过')
        return existing
    print(f'交易: 现有 {existing} → 补 {need} 笔')

    now = int(time.time())
    span = SPREAD_DAYS * 86400
    rows = []
    for _ in range(need):
        cum, ttype = 0.0, 'expense'
        for t, w in itx.TYPE_WEIGHTS:
            cum += w
            if rng.random() <= cum:
                ttype = t
                break
        lo, hi = itx.BASE_RANGE[ttype]
        account_id = rng.choice(acc_ids)
        currency = acc_ccy[account_id]
        amount = itx.gen_amount(rng.uniform(lo, hi), currency)
        category_id = None
        to_account_id = None
        if ttype == 'expense' and expense_cats:
            category_id = rng.choice(expense_cats)
        elif ttype == 'income' and income_cats:
            category_id = rng.choice(income_cats)
        elif ttype == 'transfer':
            category_id = transfer_cat
            others = [a for a in acc_ids if a != account_id]
            to_account_id = rng.choice(others) if others else None
        rows.append((
            ledger_id, ttype, amount, category_id, account_id, to_account_id,
            now - rng.randrange(span), f'基线-{ttype}' if rng.random() < 0.4 else None,
            str(uuid.uuid4()), owner_uid, owner_uid,
            1 if rng.random() < 0.05 else 0, 1 if rng.random() < 0.05 else 0,
            currency, amount,
        ))
        if len(rows) >= TX_CHUNK:
            _flush(cur, con, rows)
            rows = []
    if rows:
        _flush(cur, con, rows)
    total = cur.execute(
        "SELECT COUNT(*) FROM transactions WHERE ledger_id=?", (ledger_id,)).fetchone()[0]
    print(f'交易: 完成 {total} 笔')
    return total


def _flush(cur, con, rows):
    cur.executemany(
        """
        INSERT INTO transactions
            (ledger_id, type, amount, category_id, account_id, to_account_id,
             happened_at, note, sync_id, created_by_user_id, last_edited_by_user_id,
             exclude_from_stats, exclude_from_budget, currency_code, native_amount)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, rows)
    con.commit()


def attachment_source_files(count, from_photos, att_dir, width, height, seed):
    """产出 count 个**物理文件**的绝对路径（已存在的复用，不足的部分补生成）。"""
    os.makedirs(att_dir, exist_ok=True)
    pool = []
    if from_photos:
        pool = sorted(
            os.path.join(from_photos, f) for f in os.listdir(from_photos)
            if f.lower().endswith(('.jpg', '.jpeg', '.png')))
        if not pool:
            sys.exit(f'--from-photos {from_photos} 下没有 jpg/png')
    paths = []
    for i in range(count):
        if pool:
            src = pool[i % len(pool)]
            dst = os.path.join(att_dir, f'src-{i:05d}-{os.path.basename(src)}')
            if not os.path.exists(dst):
                shutil.copyfile(src, dst)
            paths.append(dst)
            continue
        dst = os.path.join(att_dir, f'gen-{i:05d}.jpg')
        if not os.path.exists(dst):
            _write_synthetic_jpeg(dst, i, width, height, seed)
        paths.append(dst)
    return paths


def _write_synthetic_jpeg(path, idx, width, height, seed):
    from PIL import Image, ImageDraw
    img = Image.new('RGB', (width, height))
    d = ImageDraw.Draw(img)
    rng = random.Random(seed + idx)
    step = max(64, width // 8)
    for y in range(0, height, step):          # 大块纯色：压得动，又不是全黑
        for x in range(0, width, step):
            d.rectangle([x, y, x + step, y + step],
                        fill=(rng.randrange(256), rng.randrange(256), rng.randrange(256)))
    d.rectangle([0, 0, 32, 32], fill=(idx % 256, (idx * 7) % 256, 200))  # 保证内容唯一
    img.save(path, 'JPEG', quality=80)


def seed_attachments(cur, con, ledger_id, count, files_dir, width, height):
    existing = cur.execute(
        "SELECT COUNT(*) FROM transaction_attachments a "
        "JOIN transactions t ON t.id=a.transaction_id WHERE t.ledger_id=?",
        (ledger_id,)).fetchone()[0]
    need = count - existing
    if need <= 0:
        print(f'附件已够: {existing}/{count}，跳过')
        return
    print(f'附件: 现有 {existing} → 补 {need} 个')

    tids = [r[0] for r in cur.execute(
        "SELECT id FROM transactions WHERE ledger_id=? ORDER BY id", (ledger_id,))]
    if not tids:
        sys.exit('该账本没有交易，附件无处可挂')
    # 均匀散布到全账本，而不是全挤在最老的那几笔上；只补差额（从散布序列尾部取）
    step = max(1, len(tids) // count)
    slots = tids[::step][-need:]
    now = int(time.time())
    made = 0
    for i, tid in enumerate(slots, start=existing):
        fpath = files_dir[i]
        with open(fpath, 'rb') as f:
            blob = f.read()
        sha = hashlib.sha256(blob).hexdigest()
        fname = f'sha_{sha}.jpg'
        if cur.execute("SELECT 1 FROM transaction_attachments WHERE file_name=?",
                       (fname,)).fetchone():
            continue
        w, h = _jpeg_dims(blob) or (width, height)
        cur.execute(
            "INSERT INTO transaction_attachments (transaction_id, file_name, original_name, "
            "file_size, width, height, sort_order, local_sha256, created_at) "
            "VALUES (?,?,?,?,?,?,?,?,?)",
            (tid, fname, os.path.basename(fpath), len(blob), w, h, i % 9, sha, now))
        made += 1
    con.commit()
    print(f'附件: 新增 {made} 行，物理文件在 {os.path.dirname(files_dir[0])}')


def _jpeg_dims(blob):
    """从 JPEG 头里读宽高（不引图像库也能对上真实尺寸）。失败返回 None。"""
    try:
        from PIL import Image
        import io
        with Image.open(io.BytesIO(blob)) as im:
            return im.size
    except Exception:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--tier', default='M', choices=sorted(TIERS))
    ap.add_argument('--db', required=True, help='库文件路径（从设备拉下来的那份）')
    ap.add_argument('--ledger-id', type=int)
    ap.add_argument('--tx', type=int, help='覆盖该档的交易数')
    ap.add_argument('--attachments', type=int, help='覆盖该档的附件数')
    ap.add_argument('--attachments-dir', help='物理文件落点，默认 <db 目录>/mem_seed_attachments')
    ap.add_argument('--from-photos', help='用真实照片目录里的 jpg/png 复制，而不是合成')
    ap.add_argument('--size', type=int, default=1920, help='合成附件边长（应用上限 1920）')
    ap.add_argument('--seed', type=int, default=20260919)
    args = ap.parse_args()

    tx_target, att_target = TIERS[args.tier]
    tx_target = args.tx or tx_target
    att_target = args.attachments if args.attachments is not None else att_target
    if not os.path.exists(args.db):
        sys.exit(f'找不到库文件: {args.db}（先按 docs/evidence 里的 adb 命令拉一份）')

    con = sqlite3.connect(args.db)
    con.execute("PRAGMA busy_timeout = 30000")
    cur = con.cursor()
    print(f'档位 {args.tier}: {tx_target} 笔 / {att_target} 附件 → {args.db}')

    ledger_id = pick_ledger(cur, args.ledger_id)
    owner = cur.execute("SELECT owner_user_id FROM ledgers WHERE id=?",
                        (ledger_id,)).fetchone()[0]
    t0 = time.time()
    seed_tx(cur, con, ledger_id, owner, tx_target, args.seed)
    if att_target:
        att_dir = args.attachments_dir or os.path.join(
            os.path.dirname(os.path.abspath(args.db)), 'mem_seed_attachments')
        files = attachment_source_files(att_target, args.from_photos, att_dir,
                                        args.size, args.size, args.seed)
        seed_attachments(cur, con, ledger_id, att_target, files, args.size, args.size)
    # 让内容全部落回主文件：推回设备时只推 .sqlite 也不会丢数据（B10 起应用跑 WAL）
    cur.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    con.close()

    print(f'\n用时 {time.time() - t0:.1f}s')
    print('推到设备（应用须先停止；设备侧旧旁路文件要删干净）：')
    print('  adb shell am force-stop <package>')
    print(f'  adb push "{args.db}" /data/local/tmp/piggycount.sqlite')
    print('  adb shell "run-as <package> rm -f app_flutter/piggycount.sqlite*"'
          ' && adb shell "run-as <package> cp /data/local/tmp/piggycount.sqlite app_flutter/piggycount.sqlite"')
    if att_target:
        print('  adb push "<附件目录>" /data/local/tmp/attachments')
        print('  adb shell "run-as <package> cp -r /data/local/tmp/attachments/. app_flutter/attachments/"')


if __name__ == '__main__':
    main()
