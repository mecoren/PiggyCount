/// 云端协同（PiggyCount Cloud 实时同步）总开关。
///
/// 设为 `false` 时，云端协同功能整体停用：
///  1. 运行时 [syncServiceProvider] 不会实例化 `SyncEngine`，PiggyCount Cloud
///     的实时通道完全下线，退化为 `LocalOnlySyncService`。
///  2. [piggycountCloudProviderInstance] 直接返回 `null`，不再发起任何
///     PiggyCount Cloud 网络初始化（登录 / 版本探测 / profile 同步等）。
///  3. [CloudServicePage] 中「云端协同」后端卡片被标记为「未启用」，且不可被
///     选择（onTap / onConfigure 置空）。
///  4. [mine_page] 的「同步状态」不再路由到 `PiggyCountCloudSyncPage`；
///     [ledgers_page_new] 的「加入共享账本」入口隐藏（共享账本是云端协同的
///     独占能力）。
///
/// 注意：该开关只影响 PiggyCount Cloud（路径 B 实时协同）。S3 / WebDAV /
/// Supabase / iCloud 等快照式同步（路径 A）不受影响，仍可正常使用。
const bool kPiggyCountCloudEnabled = false;
