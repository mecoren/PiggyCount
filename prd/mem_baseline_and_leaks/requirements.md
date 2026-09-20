# 内存基线与泄漏收口（B6-B10 / M10-M21）— 需求文档

## 一、背景

`docs/optimization-plan-2026-09-14.md` 把内存项 M1-M9 推过一轮，但**这条线从来没有被测过**：
上一轮定的验收（灌 1 万笔 + 200 附件，对比冷启动/首页滚动/预览峰值 RSS）未执行，全仓无任何
RSS 或峰值内存实测数据（帧率有，`docs/evidence/`）。同时源码里存在已定位、修复成本两行级别的
native 位图泄漏（全仓 `image.dispose` 零命中）。

本轮（`docs/optimization-plan-2026-09-19.md` §三）因此定为：**先测量、再收口、后重构**。

## 二、需求范围

### R1 可执行的测量流程（B6）

- 三档语料灌库脚本：S 500 笔/2 附件、M 1 万/200、L 10 万/800（L 只挂 nightly/手动）。
- 采集脚本：一次跑出 **native 侧**（RSS / 峰值 / Native Heap / Graphics / .so mmap）与
  **Dart 侧**（各 isolate 堆）两路数字，并能算出 5 分钟泄漏斜率与判级。
- 验收表列名固定，先交空表；每批改动后回填同场景前后两行。
- 应用侧常驻开销只加一处：30s 心跳把 RSS/峰值 + 内存压力事件写进**既有**日志设施。

### R2 native 位图释放（B7，M10/M11）

- 全仓每个位图产生点（`toImage` / `instantiateImageCodec`）必须在同一作用域内释放，
  且**有一条守卫测试防重构后静默退化**。

### R3 资产降采样与常驻对象（B8/B9，M12/M14-M17/M19/M16）

- 大图资产按显示位宽解码（`cacheWidth`），不再裸解原图。
- 全表进 Dart 的聚合下推到 SQL；分块读文件的字节拼接不再用 `List<int>`。
- release 下的日志队列不再无门控收 debug 级、不再每次 getter 复制 2000 条。
- 同步侧缓存的"解密后整本账本 JSON"要有上限与清理路径。
- 以 `List<int>` 当 provider family key 的点必须换成值相等的 key（永不回收）。

### R4 SQLite PRAGMA 显式化（B10，M18）

- `journal_mode` / `synchronous` / `cache_size` / `mmap_size` / `journal_size_limit` 由应用声明，
  且**每条连接**生效（本库跑在第二个 isolate，PRAGMA 是 per-connection）。
- 出口即回读断言，防止"以为设了其实没设"。

## 三、验收标准

1. `scripts/seed_mem_baseline.py` 在真实库副本上端到端跑通：行数、附件宽高与 sha、
   `integrity_check=ok`、**重跑幂等**。
2. `scripts/profile_memory.py --self-check` 通过（不连设备的那部分：解析、留空行为、
   斜率与判级）。
3. 每个批次的出口：`flutter analyze` 0 issue + 全量 `flutter test` 绿 + §13 批次记录带 file:line。
4. 内存硬门禁：B7 及以后每批附同场景 RSS 前后对比行。**无设备时按"收益未证"处理**，
   不得用算式冒充实测（见 `docs/optimization-plan-2026-09-19.md` §13 各批"门禁"小节）。
5. 位图释放守卫为**负向验证过**的测试（放过 leaky 探针必须红）。

## 四、未纳入本轮（登记在方案 §三 B11）

- **M13 归档流式（= 上一轮 S4）**：导出备份时整包进内存，峰值 ≈ 附件总量 ×3，是唯一真致
  移动端 OOM 的问题。本轮只存档设计（`archive` 3.6.1 原生支持盘到盘），不动代码：它改的是
  备份容器写序，属"触碰线上格式"，按硬约束独立立项。
- **M2 首页交易窗口化**：无 LIMIT 的全账本三连 LEFT JOIN。依赖面五处（日分组删除检测、
  日合计、月份跳转、`lastRows` 持有、搜索语义），必须两步走，不能直接换 keyset。
- 常驻遥测（`PerfMetricLog` 表 / watchdog / iOS 通道 / FPS 上报）：基线跑完仍复现不了
  用户报的 OOM 才值得加。不引 Sentry/Crashlytics（要原生 SDK，自身基线 10-20MB）。
