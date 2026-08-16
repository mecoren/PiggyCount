# WebDAV 新设备同步认证失败修复需求（webdav_new_device_auth_prompt）

## 需求理解

用户在新设备上配置 WebDAV 并输入正确的密码后，同步时报「云端探测失败，请检查网络后重试」；实际凭据/网络可能并无问题，却被误导为网络故障。要求：新设备同步时应主动、准确地提示用户输入密码（加密密码 / WebDAV 凭据），错误信息如实分类。

## 故障现场（用户确认）

- 弹出了「输入同步加密密码」对话框 → 输入正确密码后 → 弹「云端探测失败，请检查网络后重试」。
- 该文案仅存在于 `encryption_dialogs.dart` 的 `EnableFromCloudProbeFailedException` 分支（l10n key: `saltMismatchProbeFailed`），即 `enableFromCloud` 的云端探测（list/download）环节失败。

## 根因（代码级）

- **G1 401 被误报为网络错误**：`WebDAVStorageService` 仅识别 404（`_isNotFound`），不识别 401/403；密码错误抛通用 `CloudStorageException`，被 `enableFromCloud` 统一包装为 `EnableFromCloudProbeFailedException` → UI 提示「检查网络」。core 包已有 `CloudAuthException` 但 WebDAV 层从未使用。
- **G2 凭据更新后仍用旧密码探测（陈旧管理器）**：`WidgetRefDeps` 在启动检查时一次性捕获 `TransactionsSyncManager` 实例；用户中途在云服务页重输 WebDAV 密码后 provider 会重建新管理器，但进行中的恢复流程（`handleSaltMismatch` → `promptPasswordAndActivate`）仍持有旧凭据实例 → 探测持续 401，表现为「重输正确密码仍失败」。
- **G3 探测异常被静默吞掉**：`_isCloudCiphertextLocallyDisabled` 的探测下载失败时 `catch → return false`，哨兵不触发 → 密码框不弹；且启动检查器对非哨兵 error 状态（未抛异常的）静默跳过，可能误报「已是最新」。

## 需求范围

### R1 401/403 如实分类（G1）
- WebDAV 层（provider 初始化 + storage 读写列举）识别 401/403，抛 `CloudAuthException`。
- `enableFromCloud` 探测时透传认证失败语义（新异常 `EnableFromCloudAuthException`）。
- 恢复对话框区分展示：「WebDAV 账号或密码错误，请重新配置」并可跳转云服务页；其余失败保留网络提示。

### R2 恢复流程使用最新凭据（G2）
- `promptPasswordAndActivate` 内部每次通过 `ref.read(syncServiceProvider)` 解析**当前** `TransactionsSyncManager`，不再依赖调用方捕获的旧实例；两处调用方同步调整。

### R3 新设备主动提示可靠触达（G3，用户主诉）
- 新设备同步检测到云端密文 → 主动弹加密密码框（现有哨兵链路保持）。
- 探测环节认证失败 → 明确提示重新配置 WebDAV（引导输入凭据），不再显示「检查网络」。
- 启动检查器：非哨兵 error 状态计入失败账本（对齐 P1-3「失败不得报已最新」），错误文案区分认证失败/网络超时。

## 边界与风险

- WebDAV 服务器差异化错误文案：401/403 判定沿用「结构化状态码优先、字符串匹配兜底」策略（与 `_isNotFound` 一致）。
- `CloudAuthException` 为既有类型，新增 `EnableFromCloudAuthException` 放在应用层 `encryption_service.dart`，不动 core 包公共 API 结构。
- 修改 `promptPasswordAndActivate` 签名（移除 `syncManager` 参数）需同步 2 处调用方；`encryption_settings_page` 的 `_onSetPassword` 探测失败分支（US-3 首设备确认流程）不在本期范围，行为保持不变。

## 验收标准

- 新设备配置错误 WebDAV 密码 + 云端为密文：同步时或提示重新配置 WebDAV（认证错误文案），或弹加密密码框后明确报「账号或密码错误」；绝不显示「请检查网络后重试」。
- 新设备配置正确密码：弹加密密码框 → 输入正确密码 → 探测成功激活密钥 → 同步恢复，全程无需重启 App。
- 恢复流程中途修改 WebDAV 密码后重试：探测使用新凭据。
- `flutter analyze` 无新增告警。
