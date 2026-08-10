---
name: fix-sync-password-error-feedback
overview: 修复B设备首次进入应用输入同步密码后，密码错误/密钥激活失败时无前端提示、错误只在设置页显示的问题。
---

我已经完整掌握了代码结构和所有调用点。现在制定最终计划。

我已经确认了所有关键细节：

1. `StartupSyncCheckerDeps.handleSaltMismatch()` 返回 `Future<bool>`（line 140）
2. 调用点：line 237（主流程）、389/401（_applyAll）、481/492（_confirmEach）
3. `promptPasswordAndActivate` 返回 `Future<bool>`（encryption_dialogs.dart line 32）
4. `_runInternal` line 242-244 静默返回是主根因
5. 现有 l10n key：`cloudSyncEncryptWrongPassword`（密码错误）、`startupSyncCheckTitle`、`saltMismatchNeedPasswordHint`

现在输出最终计划。

<plan_result>
<req>

## 问题确认

问题确实存在，根因已查明。

## 场景

- A 设备已同步云端并修改同步密码 → 云端 salt/密钥更新
- B 设备首次进入应用，启动检查（StartupSyncChecker）检测到加密哨兵（salt_mismatch_need_password / cloud_encrypted_locally_disabled）→ 弹出密码输入框
- 用户输入完成后，前端**无任何反馈提示**（不弹对话框/不弹提示条），被直接退回主界面
- 错误仅在"设置 → 同步"页（CloudSyncPage）显示

## 根因

`lib/cloud/startup_sync_checker.dart` 的 `_runInternal` 方法（约 line 242-244）：
当 `handleSaltMismatch()` 返回 `false`（密码错误/激活失败或用户取消）时，代码只执行 `controller.dismiss()` + `return`，静默退出，没有任何用户可见反馈。虽然 `promptPasswordAndActivate` 内部在密码错误时尝试弹"密码错误"框，但在 overlay 移除的时序窗口内该框可能被吞/叠加错层，且此分支无兜底提示，导致用户完全不知情，只能事后到设置页查看。

## 核心需求

- 在 B 设备首次输入同步密码后，无论密码正确与否，都必须在前端直接弹窗提示结果
- 密码错误/激活失败时，明确告知用户"密钥未激活、同步未恢复"，并给出后续指引（重新输入或去同步设置）
- 用户主动取消密码框时，给予温和/不打扰的处理
- 区分"用户取消"与"激活失败"两种场景，避免重复弹窗
</req>

<tech>

## 技术方案

### 问题定位（已确认）

- 主根因文件：`lib/cloud/startup_sync_checker.dart`（line 230-244）
- 密码框/错误框定义：`lib/pages/cloud/encryption_dialogs.dart`（`promptPasswordAndActivate`，line 32-104）
- 兜底提示方法（已存在但主流程未调用）：`deps.showLegacyError`（startup_sync_checker.dart line 681-688）
- 接口：`StartupSyncCheckerDeps.handleSaltMismatch()` 返回 `Future<bool>`（line 140），调用点：line 237（主流程）、389/401（_applyAll）、481/492（_confirmEach）

### 实现策略

引入**三态结果枚举**以精确区分场景，替代当前仅返回 `bool` 的设计，从而在"用户取消"与"激活失败"两种情况下给出不同反馈，避免重复弹窗。

1. **新增三态枚举** `SaltMismatchRecoveryResult { activated, cancelled, failed }`

- `activated`：密码正确、密钥激活成功
- `cancelled`：用户主动取消密码框
- `failed`：密码错误/激活失败（含 SaltMismatch、ProbeFailed、Corrupted 等异常）

2. **修改 `promptPasswordAndActivate`**（encryption_dialogs.dart）：返回值由 `bool` 改为三态枚举，内部各分支精确映射（取消→cancelled、密码错误/异常→failed、成功→activated）。保留内部错误对话框（密码错误仍弹"密码错误"），这是第一层反馈。

3. **修改 `handleSaltMismatch`**（startup_sync_checker.dart line 140 + 665-673）：返回类型同步改为三态枚举，透传 `promptPasswordAndActivate` 结果。

4. **修复 `_runInternal` 主流程**（line 242-244）——核心修复点：

- `activated` → `return _runInternal(isRetry: true)` 重试（保持现状）
- `failed` → 调用 `deps.showLegacyError(...)` 弹明确提示："密钥未能激活、同步未恢复，请重试或到同步设置重新输入密码"
- `cancelled` → 静默/温和返回（不打扰，保持现有行为）

5. **适配其他调用点**（_applyAll line 389/401、_confirmEach line 481/492）：将 `if (activated)` 判断改为对 `result == activated`，`failed` 时补充 `showLegacyError` 明确提示（原"用户取消"文案过于笼统，需区分）。

### 关键设计决策

- **用三态而非在内部重复弹框**：`promptPasswordAndActivate` 内部密码错误时已弹"密码错误"框。若仅靠主流程兜底会导致"重复弹窗"。三态枚举让主流程只在 `failed` 且内部错误框可能被吞时提供兜底，逻辑清晰、无重复。
- **复用现有方法**：错误提示复用已存在的 `deps.showLegacyError`（AppDialog.error），无需新增 import；文案复用/新增 l10n key。
- **控制影响范围**：仅改签名返回类型与 5 个调用点，不改变 `StartupSyncCheckerDeps` 接口方法数量与流程编排，不触碰路径 B（PiggyCount Cloud）与 `_applyAll` 汇总逻辑。

### 文案

- 复用已有 key：`cloudSyncEncryptWrongPassword`（"密码错误"）、`startupSyncCheckTitle`（"云端有更新"）
- 新增一个描述性 key（如 `startupSyncRecoveryFailedHint`）：说明"密钥激活失败，同步未恢复，请重新输入密码或到同步设置操作"，用于主流程兜底提示。需同步更新 en/zh/zh_TW/ko 四个 arb 文件（app_en.arb、app_zh.arb、app_zh_TW.arb、app_ko.arb）。

### 目录结构

```
lib/
├── cloud/
│   └── startup_sync_checker.dart    # [MODIFY] 新增 SaltMismatchRecoveryResult 枚举；修改 handleSaltMismatch 签名；修复 _runInternal 主流程 line 242-244；适配 _applyAll/_confirmEach 调用点
├── pages/cloud/
│   └── encryption_dialogs.dart      # [MODIFY] promptPasswordAndActivate 返回值改为三态枚举，各分支精确映射
└── l10n/
    ├── app_en.arb                   # [MODIFY] 新增 startupSyncRecoveryFailedHint
    ├── app_zh.arb                   # [MODIFY] 新增 startupSyncRecoveryFailedHint
    ├── app_zh_TW.arb                # [MODIFY] 新增 startupSyncRecoveryFailedHint
    └── app_ko.arb                   # [MODIFY] 新增 startupSyncRecoveryFailedHint
```

### 实施要点

- **时序安全**：主流程 line 235-236 先 dismiss overlay 再 `Future.delayed(Duration.zero)` 的时序保持不变；在 `failed` 分支通过 `deps.showLegacyError` 弹框前，确保 overlay 已 detach（dismiss 已同步 detach，见 app.dart line 192-196）。
- **测试**：`StartupSyncChecker` 有 mock 依赖（WidgetRefDeps / 测试 mock 的 `handleSaltMismatch`），改签名后需同步更新所有 mock 实现与测试用例（test/ 目录下涉及 handleSaltMismatch 的测试）。
- **无新增依赖**：全部基于现有 Flutter/Riverpod/AppDialog 能力。
</tech>

<extensions>

## 可用扩展

- **code-explorer**（subagent）：已用于前期探索，确认了根因代码位置、接口定义与所有调用点。后续若需验证更多调用方或测试文件对 `handleSaltMismatch` 的使用，可复用。
</extensions>

<todolist>
<item id="define-result-enum" deps="">在 startup_sync_checker.dart 新增 SaltMismatchRecoveryResult 三态枚举（activated/cancelled/failed）</item>
<item id="modify-dialog-return" deps="define-result-enum">修改 encryption_dialogs.dart 的 promptPasswordAndActivate 返回值，各分支精确映射为三态</item>
<item id="modify-handle-salt" deps="modify-dialog-return">修改 handleSaltMismatch 签名返回三态，并修复 _runInternal 主流程 failed 分支弹提示</item>
<item id="adapt-callers" deps="modify-handle-salt">适配 _applyAll 与 _confirmEach 调用点，failed 时补充明确错误提示</item>
<item id="add-l10n" deps="adapt-callers">在 en/zh/zh_TW/ko 四个 arb 新增密钥激活失败提示文案并运行 gen-l10n</item>
<item id="update-tests" deps="modify-handle-salt">同步更新 test 目录下 handleSaltMismatch 的 mock 与相关测试用例</item>
</todolist>
</plan_result>