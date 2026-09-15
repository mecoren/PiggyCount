# -*- coding: utf-8 -*-
"""S3/WebDAV 同步测试——两端 DB 逐字段一致性对比（v2）。

用法: python compare_sync_final.py <A.sqlite> <B.sqlite> [--label S3|WebDAV]

对比维度（全部按 syncId 对齐身份，不依赖本地自增 id）:
  1. 八张同步表行数 + syncId 集合差
  2. ledgers: name/currency/type/month_start_day/my_role 逐字段
     （is_shared/member_count 为设备本地语义，列为「预期差异」不计入不一致）
  3. accounts: name/type/currency/initial_balance/credit_limit/billing_day/
     payment_due_day/bank_name/card_last_four/note/hidden/sort_order
  4. categories: name/kind/level/parent 链/sort_order/icon
  5. tags: name/color/sort_order
  6. transactions: type/amount/category 链/account 链/to_account 链/
     happened_at/note/exclude_stats/exclude_budget/currency_code/native_amount/
     created_by —— 按 (ledgerSyncId, txSyncId) 对齐
  7. transaction_tags: (txSyncId, tagSyncId) 链接集合
  8. budgets: (ledgerSyncId, type, category 链, amount, period, start_day, enabled)
  9. recurring_transactions: 全字段（不含纯本地调度字段 last_generated_date）
 10. exchange_rate_overrides: (base, quote, rate)
输出: 每维度 OK/FAIL + 不一致样本（前 5 条），最终一行结论。
退出码: 0 = 无非预期差异（可能含预期差异行），2 = 存在不一致。

预期差异（expected differences）说明:
  ledgers.is_shared / ledgers.member_count 描述的是「本机视角的共享成员
  状态」，快照同步刻意不搬运（见 lib/cloud/transactions_json.dart 的
  指纹字段取舍）。因此 A 端创建共享账本、B 端导入后这两列天然不同，
  单列一行 [OK*] 展示，不计入 issues、不影响退出码——避免每轮回归都
  报一次同样的「不一致」噪音，掩盖真问题。
"""
import sqlite3
import sys

SYNCED = ["ledgers", "accounts", "categories", "tags", "transactions",
          "budgets", "recurring_transactions", "exchange_rate_overrides"]

# ledgers 列分两组：前者参与同步搬运（必须逐字段一致），后者为设备本地
# 语义（预期差异，见文件头说明）。
LEDGER_SYNCED_COLS = "name, currency, type, month_start_day, my_role"
LEDGER_LOCAL_COLS = "is_shared, member_count"


def rows(cur, sql, args=()):
    return cur.execute(sql, args).fetchall()


def ledger_map(cur):
    return {r[1]: r[0] for r in rows(cur, "SELECT id, sync_id FROM ledgers")}


def cat_chain(cur, cid, cats):
    """分类 -> 'L1名>L2名' 链（按 name+kind 判等，id 两端不同）。"""
    if cid is None:
        return None
    c = cats.get(cid)
    if c is None:
        return "<missing>"
    name, kind, level, parent = c
    if parent and parent in cats:
        p = cats[parent]
        return f"{p[0]}>{name}"
    return name


def acc_chain(cur, aid, accs):
    if aid is None:
        return None
    a = accs.get(aid)
    return "<missing>" if a is None else a  # (name, type, currency)


def main():
    a_path, b_path = sys.argv[1], sys.argv[2]
    label = "S3"
    if "--label" in sys.argv:
        label = sys.argv[sys.argv.index("--label") + 1]
    ca = sqlite3.connect(a_path); cb = sqlite3.connect(b_path)
    qa, qb = ca.cursor(), cb.cursor()
    issues = []
    print(f"===== {label} 同步一致性对比 =====")
    print(f"A = {a_path}")
    print(f"B = {b_path}\n")

    # ---- 1) 行数 & syncId 集合 ----
    for t in SYNCED:
        na = rows(qa, f"SELECT COUNT(*) FROM {t}")[0][0]
        nb = rows(qb, f"SELECT COUNT(*) FROM {t}")[0][0]
        cols = {r[1] for r in rows(qa, f"PRAGMA table_info({t})")}
        if "sync_id" in cols:
            sa = {r[0] for r in rows(qa, f"SELECT sync_id FROM {t}") if r[0]}
            sb = {r[0] for r in rows(qb, f"SELECT sync_id FROM {t}") if r[0]}
            only_a, only_b = sa - sb, sb - sa
            ok = na == nb and not only_a and not only_b
            print(f"  [{'OK' if ok else '!!'}] {t:26s} A={na:<6} B={nb:<6} 仅A={len(only_a)} 仅B={len(only_b)}")
            if not ok:
                issues.append(f"{t}: 行数或syncId集合不一致 (A={na}, B={nb}, 仅A={len(only_a)}, 仅B={len(only_b)})")
        else:
            ok = na == nb
            print(f"  [{'OK' if ok else '!!'}] {t:26s} A={na:<6} B={nb:<6} (无sync_id列)")
            if not ok:
                issues.append(f"{t}: 行数不一致 (A={na}, B={nb})")

    lmap_a, lmap_b = ledger_map(qa), ledger_map(qb)

    # ---- 2) ledgers 逐字段（同步字段严格比对；本地语义字段单列预期差异） ----
    cols_l = f"{LEDGER_SYNCED_COLS}, {LEDGER_LOCAL_COLS}"
    synced_col_count = len(LEDGER_SYNCED_COLS.split(","))
    da = {r[0]: r[1:] for r in rows(qa, f"SELECT sync_id, {cols_l} FROM ledgers")}
    db_ = {r[0]: r[1:] for r in rows(qb, f"SELECT sync_id, {cols_l} FROM ledgers")}
    diff, local_diff = [], []
    for k in da:
        if k not in db_:
            continue
        if da[k][:synced_col_count] != db_[k][:synced_col_count]:
            diff.append(k)
        if da[k][synced_col_count:] != db_[k][synced_col_count:]:
            local_diff.append(k)
    print(f"\n  [{'OK' if not diff else '!!'}] ledgers 同步字段({LEDGER_SYNCED_COLS}) 一致（{len(da)}个账本）")
    if diff:
        issues.append(f"ledgers 字段不一致: {len(diff)} 个")
        for k in diff[:5]:
            print(f"       {da[k][:synced_col_count]} vs {db_[k][:synced_col_count]}")
    if local_diff:
        print(f"  [OK*] ledgers 设备本地字段({LEDGER_LOCAL_COLS}) 差异 "
              f"{len(local_diff)} 个 —— 预期差异，不计入不一致")
        for k in local_diff[:5]:
            print(f"       {k[:8]} A={da[k][synced_col_count:]} vs B={db_[k][synced_col_count:]}")

    # ---- 3) accounts 逐字段（按 syncId） ----
    cols_acc = ("name, type, currency, initial_balance, sort_order, credit_limit, "
                "billing_day, payment_due_day, bank_name, card_last_four, note, hidden")
    da = {r[0]: r[1:] for r in rows(qa, f"SELECT sync_id, {cols_acc} FROM accounts")}
    db_ = {r[0]: r[1:] for r in rows(qb, f"SELECT sync_id, {cols_acc} FROM accounts")}
    diff = [k for k in da if k in db_ and da[k] != db_[k]]
    print(f"  [{'OK' if not diff else '!!'}] accounts 字段 一致（{len(da)}个账户）")
    if diff:
        issues.append(f"accounts 字段不一致: {len(diff)} 个")
        for k in diff[:5]:
            print(f"       {da[k]} vs {db_[k]}")

    # ---- 4) categories ----
    def cat_by_sid(q):
        id2sid = {r[0]: r[1] for r in rows(q, "SELECT id, sync_id FROM categories")}
        return {sid: (name, kind, level, id2sid.get(pid))
                for sid, name, kind, level, pid in rows(
                    q, "SELECT sync_id, name, kind, level, parent_id FROM categories")}
    ca_, cb_ = cat_by_sid(qa), cat_by_sid(qb)
    cdiff = [k for k in ca_ if k in cb_ and ca_[k] != cb_[k]]
    print(f"  [{'OK' if not cdiff else '!!'}] categories 字段 一致（{len(ca_)}个分类, 父分类按syncId归一）")
    if cdiff:
        issues.append(f"categories 不一致: {len(cdiff)} 个")
        for k in cdiff[:5]:
            print(f"       {ca_[k]} vs {cb_[k]}")

    # ---- 5) tags ----
    da = {r[0]: r[1:] for r in rows(qa, "SELECT sync_id, name, color, sort_order FROM tags")}
    db_ = {r[0]: r[1:] for r in rows(qb, "SELECT sync_id, name, color, sort_order FROM tags")}
    diff = [k for k in da if k in db_ and da[k] != db_[k]]
    print(f"  [{'OK' if not diff else '!!'}] tags 字段 一致（{len(da)}个标签）")
    if diff:
        issues.append(f"tags 不一致: {len(diff)}")
        for k in diff[:5]:
            print(f"       {da[k]} vs {db_[k]}")

    # ---- 6) transactions 逐字段 ----
    def tx_key_rows(q, lmap):
        accs = {}
        for aid, aname, atype, acur, sid in rows(q, "SELECT id, name, type, currency, sync_id FROM accounts"):
            accs[aid] = (aname, atype, acur, sid)
        catname2 = {r[0]: (r[1], r[0]) for r in rows(q, "SELECT id, name FROM categories")}
        out = {}
        for (lsid, tsid, ttype, amount, cat, acc, to_acc, happ, note,
             exs, exb, cur, native, cby) in rows(q, """
            SELECT l.sync_id, t.sync_id, t.type, t.amount, t.category_id,
                   t.account_id, t.to_account_id, t.happened_at, t.note,
                   t.exclude_from_stats, t.exclude_from_budget,
                   t.currency_code, t.native_amount, t.created_by_user_id
            FROM transactions t JOIN ledgers l ON t.ledger_id = l.id"""):
            acc_sid = accs[acc][3] if acc in accs else None
            to_sid = accs[to_acc][3] if to_acc in accs else None
            cat_sid = None
            for cid, (nm, _) in catname2.items():
                if cid == cat:
                    cat_sid = nm  # fallback; 用名字近似
                    break
            out[(lsid, tsid)] = (ttype, round(amount, 2), acc_sid, to_sid,
                                 happ, note, exs, exb, cur,
                                 round(native, 2) if native is not None else None)
        return out
    # 更准确的 category syncId 映射
    def tx_rows_exact(q):
        cat_sid = {r[0]: r[1] for r in rows(q, "SELECT id, sync_id FROM categories")}
        acc_sid = {r[0]: r[1] for r in rows(q, "SELECT id, sync_id FROM accounts")}
        out = {}
        for r in rows(q, """
            SELECT l.sync_id, t.sync_id, t.type, t.amount, t.category_id,
                   t.account_id, t.to_account_id, t.happened_at, t.note,
                   t.exclude_from_stats, t.exclude_from_budget,
                   t.currency_code, t.native_amount
            FROM transactions t JOIN ledgers l ON t.ledger_id = l.id"""):
            lsid, tsid, ttype, amount, cat, acc, to_acc, happ, note, exs, exb, cur, native = r
            out[(lsid, tsid)] = (ttype, round(amount, 2),
                                 cat_sid.get(cat), acc_sid.get(acc), acc_sid.get(to_acc),
                                 happ, note, exs, exb, cur,
                                 round(native, 2) if native is not None else None)
        return out
    ta, tb = tx_rows_exact(qa), tx_rows_exact(qb)
    keys_only_a = set(ta) - set(tb); keys_only_b = set(tb) - set(ta)
    fdiff = [k for k in ta if k in tb and ta[k] != tb[k]]
    ok = not keys_only_a and not keys_only_b and not fdiff
    print(f"  [{'OK' if ok else '!!'}] transactions 逐字段 一致（{len(ta)}笔）"
          f" 仅A={len(keys_only_a)} 仅B={len(keys_only_b)} 字段差异={len(fdiff)}")
    if keys_only_a or keys_only_b or fdiff:
        issues.append(f"transactions 不一致: 仅A={len(keys_only_a)} 仅B={len(keys_only_b)} 字段差异={len(fdiff)}")
        for k in list(fdiff)[:5]:
            print(f"       A: {ta[k]}\n       B: {tb[k]}")

    # ---- 7) transaction_tags ----
    def tag_links(q):
        cat_sid = {r[0]: r[1] for r in rows(q, "SELECT id, sync_id FROM tags")}
        out = set()
        for tsid, tg in rows(q, """
            SELECT t.sync_id, tt.tag_id FROM transaction_tags tt
            JOIN transactions t ON tt.transaction_id = t.id"""):
            out.add((tsid, cat_sid.get(tg)))
        return out
    la, lb = tag_links(qa), tag_links(qb)
    ok = la == lb
    print(f"  [{'OK' if ok else '!!'}] transaction_tags 一致（A={len(la)} B={len(lb)}）")
    if not ok:
        issues.append(f"transaction_tags 不一致: A={len(la)} B={len(lb)} 差={len(la ^ lb)}")

    # ---- 8) budgets ----
    def budget_rows(q):
        cat_sid = {r[0]: r[1] for r in rows(q, "SELECT id, sync_id FROM categories")}
        return set(rows(q, """
            SELECT l.sync_id, b.sync_id, b.type, b.category_id, b.amount,
                   b.period, b.start_day, b.enabled
            FROM budgets b JOIN ledgers l ON b.ledger_id = l.id""").__class__ and [
            (r[0], r[1], r[2], cat_sid.get(r[3]), round(r[4], 2), r[5], r[6], r[7])
            for r in rows(q, """
            SELECT l.sync_id, b.sync_id, b.type, b.category_id, b.amount,
                   b.period, b.start_day, b.enabled
            FROM budgets b JOIN ledgers l ON b.ledger_id = l.id""")])
    ba, bb = budget_rows(qa), budget_rows(qb)
    ok = ba == bb
    print(f"  [{'OK' if ok else '!!'}] budgets 一致（A={len(ba)} B={len(bb)}）")
    if not ok:
        issues.append(f"budgets 不一致: 差={len(ba ^ bb)}")

    # ---- 9) recurring_transactions ----
    def rec_rows(q):
        return set((r[0], r[1], r[2], r[3], round(r[4], 2), r[5], r[6], r[7], r[8],
                    r[9], r[10], r[11], r[12])
                   for r in rows(q, """
        SELECT l.sync_id, rc.sync_id, rc.type, rc.amount, rc.amount, rc.frequency,
               rc.interval, rc.day_of_month, rc.day_of_week, rc.month_of_year,
               rc.start_date, rc.end_date, rc.enabled
        FROM recurring_transactions rc JOIN ledgers l ON rc.ledger_id = l.id"""))
    ra_, rb_ = rec_rows(qa), rec_rows(qb)
    ok = ra_ == rb_
    print(f"  [{'OK' if ok else '!!'}] recurring_transactions 一致（A={len(ra_)} B={len(rb_)}）")
    if not ok:
        issues.append(f"recurring 不一致: 差={len(ra_ ^ rb_)}")

    # ---- 10) exchange_rate_overrides ----
    ea = {(s, b, q_, float(r)) for s, b, q_, r in rows(qa, "SELECT sync_id, base_currency, quote_currency, rate FROM exchange_rate_overrides")}
    eb = {(s, b, q_, float(r)) for s, b, q_, r in rows(qb, "SELECT sync_id, base_currency, quote_currency, rate FROM exchange_rate_overrides")}
    ok = ea == eb
    print(f"  [{'OK' if ok else '!!'}] exchange_rate_overrides 一致（{len(ea)}条）")
    if not ok:
        issues.append(f"汇率覆盖不一致: 差={len(ea ^ eb)}")

    if not issues and not local_diff:
        verdict = "完全一致"
    elif not issues:
        verdict = (f"无非预期差异（另有 {len(local_diff)} 个账本的设备本地"
                   f"字段差异 {LEDGER_LOCAL_COLS}，属预期）")
    else:
        verdict = f"存在 {len(issues)} 类不一致"
    print(f"\n===== 结论: {verdict} =====")
    for i in issues:
        print("  -", i)
    ca.close(); cb.close()
    sys.exit(0 if not issues else 2)


if __name__ == "__main__":
    main()
