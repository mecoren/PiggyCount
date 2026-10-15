# 日期/时间选择器数字键盘输入 — 设计文档

> 需求见同目录 `requirements.md`。本文档写「怎么实现」与取舍，不重复需求背景。
> 已确认口径：定宽数字串 / 仅日期时间选择器 / 先文档后代码。

## 一、需求理解

给四个滚轮抽屉（日期 ymd/ym/y、两步流的日期步与时间步、时分选择器）接上**物理数字键盘**通路：抽屉里没有输入框、不弹输入法，按键直接路由到滚轮既有的选值逻辑，并按「年 4 位、其余 2 位」的**定宽数字串**自动分段 —— 于是在 MuMu 模拟器 / 投屏下，`20261015` 敲完即选中 2026-10-15。

实现上**不需要新通道**：金额位已经跑通了「框架 `HardwareKeyboard` + 原生 `MainActivity.dispatchKeyEvent` → `HardwareKeyBridge`」双通路（`AMOUNT` 侧注释见 `amount_editor_sheet.dart:1316-1341`），本需求只需把同一套通路接进抽屉，并把两边共用的「Android keyCode → 逻辑键」映射表抽出来去重。

## 二、关键技术决策

### 决策 1：复用双通路 + owner 引用计数，抽屉关闭必须撤销捕获

抽屉（四处的 State）在 `initState` / `dispose` 各自成对做三件事：

```dart
HardwareKeyboard.instance.addHandler(_onKey);          // 框架层通路
HardwareKeyBridge.addListener(_onNativeKey);           // 原生 Activity 层通路
HardwareKeyBridge.setCaptureOwner(this, true/false);   // 打开/撤销原生捕获
```

依据与风险：`HardwareKeyBridge` 是广播式（`hardware_key_bridge.dart:67-69`）+ owner 引用计数（`hardware_key_bridge.dart:47-52`），所以「金额位与抽屉同时保活」不会互相抢键 —— 两边都收到事件，各按自身闸门判定。**但「只 addListener 不 setCaptureOwner」会让 MuMu/投屏注入完全无效**（原生不转发），**「只 setCaptureOwner 不撤销」会让抽屉关闭后持续吞数字键**（`MainActivity.dispatchKeyEvent` 对捕获集合一律 `return true`，见 `MainActivity.kt:287-292`）。这两条互为镜像，是本需求最高危的实现细节，测试里都要锁。

抽屉的注册时刻：`_DateStepPicker` / `_TimeStepPicker` 是**两个独立的 modal route**（`wheel_date_picker.dart:247-266`），必须各自注册、各自撤销，不能只在外层 `showWheelDateTimePicker` 里做一次。

### 决策 2：输入模型 = 定宽数字串 + 「三态列规则」

每列有固定宽度 `width`（年 4，其余 2）与动态值域 `[min, max]`。列内维护 `typedDigits`（本次键入到该列的数字串，**定案不清空**，仅"用户显式切列"时重置 —— 见决策 4）。逐键处理：

```
键入数字 d：
  col  = 当前段
  cand = col.typedDigits + d
  v    = 取 cand 最后 width 位后解析（位数不足则按实际位数解析）
  if v > col.max:                       # ① 越界
      if col 是末段: col.typedDigits = d; apply(v=d)      # 末段重开一位
      else:         前进到下一段（自动）；把 d 递归投进下一段
  else:                                 # ② 命中
      col.typedDigits = cand
      apply(clamp(v, col.min, col.max))
      if col.typedDigits.length == col.width: 前进到下一段（自动）
```

三种情形合起来给出「完全不需要切列键」的手感，用一个例子自证（`WheelTimePicker`，时 [0,23] 分 [0,59]）：

| 键入 | 时段 | 分段 | 说明 |
|---|---|---|---|
| `7` | digits=`7` → 07 | — | 1 位缓冲，不前进 |
| `0` | `70 > 23` → **越界**：时段定案 07，`0` 前推 | digits=`0` → 00 | 规则 ① |
| `5` | — | `05 → 05`（长度 = 2 → 定案） | 规则 ② |
| 结果 | 07:05 ✅ | | |

`20261015` 同理逐段推进（年 `2026` 达 4 位自动前进 → 月 `10` → 日 `15`），`13` `45` → 13:45。

**为什么选它**：任何输入都**确定**，没有定时器（超时自动定案那类手感不确定、不可测）。歧义只在一处 —— 「只想改某一列怎么办」，由决策 5 的 `.` 分段键补上，且只用小键盘就能完成。

### 决策 3：年段用「高位前缀」，其余段用「直接数值」

`min/max` 裁剪靠 `clamp`，但**中间态的取值口径两段不同**：

| 段 | 中间态口径 | `2` | `20` | `202` | `2026` |
|---|---|---|---|---|---|
| 年（width 4，min ≥ 1000） | 前缀 × 10^(4-len) 后 clamp | 2000 | 2000 | 2020 | 2026 |
| 月/日/时/分/秒（width 2） | 前缀本身后 clamp | 2 | 20 | — | — |

依据：年份是「4 位整体」，键入前 3 位表达的是**高位前缀**；而月/日/时的键入 `1` 用户心里想的就是 1（而不是 10）。两条口径各管一类，实现上用枚举 `WheelKeyPrefixMode { leadingZeros, direct }` 显式标注，避免"靠 min 大小猜"的隐式约定。

年段的中间态显示（`202` → 2020）是**唯一不精确的中间态**，最终值恒正确；需求 `requirements.md` 风险 5 已如实登记，不为此引入自定义输入态渲染（会显著加复杂度，收益只是中间态好看）。

### 决策 4：退格 = 「跨段单调回退」，不做完美撤销

`typedDigits` **定案时不清空**，只在「用户显式切列」时重置 —— 这是退格能跨段工作的前提：

- 退格：从当前段往前找第一个 `typedDigits` 非空的段 → 删其最后一位并按剩余串重算生效；剩余串为空则值保持当前生效值（只清空缓冲）。
- 例：`20261015` 后退格 → 日段 `15` → `1`（日 = 1）；再退格 → 日段清空、当前段移回月段；再退格 → 月段 `10` → `1`（月 = 1）。

**明确不做的**：「回到打开抽屉那一刻的初值」。要做到得存整条键入历史的快照栈，收益仅是"连退回到最初"，代码量翻倍（YAGNI）。因此退格是**单调、可预期、不会崩**的，而不是"完美 undo"。

### 决策 5：按键映射表（小键盘优先，不依赖方向键）

| 键（框架逻辑键 / 原生 keyCode） | 行为 |
|---|---|
| `digit0-9` / `numpad0-9`（7..16 / 144..153） | 投进当前段（决策 2） |
| `Backspace` / `delete`（67 / 112） | 退格（决策 4） |
| `.` `,` `/`（56 / 55 / 158 / 76 / 154） | **分段**：定案当前段并前进（不改变当前段值）；补上「只改某列」的能力 |
| `+` `-` / `numpadAdd` `numpadSubtract`（81 / 157 / 69 / 156） | 当前段 ±1（clamp 到段值域，并清空该段缓冲，避免与键入前缀混淆） |
| `↑` `↓`（keyCode 19 / 20） | 当前段 ±1（与 `+` `-` 等价） |
| `←` `→`（keyCode 21 / 22）、`Tab` / `Shift+Tab` | 切换当前段（定案当前段、重置目标段缓冲） |
| `Enter` / `numpadEnter`（66 / 160） | = 顶栏钩子：定案全部段后 `Navigator.pop(结果)` |
| `Esc`（111） | = 顶栏 X：`Navigator.maybePop()` |
| 其它（如 `*`） | **不消费**，返回 false |

两处取舍：

1. **`TAB` 不进原生捕获集合**。原生 `isCapturedKey`（`MainActivity.kt:297-308`）只新增方向键 `19/20/21/22`，不新增 `TAB`(61)。理由：原生捕获集合里的键一律被吞（`return true`），吞掉 `TAB` 会破坏系统级键盘导航 / 无障碍；而 `TAB` 在真机蓝牙键盘、桌面端、widget 测试里**框架层通路本来就能收到**，不该为了模拟器去牺牲系统键。
2. **不引入 `PageUp/PageDown` 的 ±10**。小键盘上没有这两个键，加了只有方向键键盘用得上，而 `↑`/`↓` 已覆盖 ±1；避免一条几乎测不到的路径（YAGNI）。

### 决策 6：键盘 apply 必须驱动滚轮视觉，与触摸共用同一 apply 路径

键盘改了值不同步控制器，就会「值变了但滚轮没动」；同步控制器（`jumpToItem`）又会触发 `onSelectedItemChanged` 回调。既有触摸路径的同步写法是 `WidgetsBinding.instance.addPostFrameCallback((_) => _ctrl.jumpToItem(i))`（`wheel_date_picker.dart:150-163`）。

落法：把「设值 + 联动同步（年改 → 月/日裁剪与滚动位置、月改 → 日裁剪与滚动位置）」抽成 `_setYear/_setMonth/_setDay` 等**唯一入口**，触摸回调与键盘通路都调用它。收敛依据：这套逻辑本身幂等（同值重入得到同结果；`jumpToItem` 到相同 index 不再触发回调），因此「键盘射入 + 回调回流」不会发散 —— 这也保证 `requirements.md` AC-R1 #1 的「滚轮实时跟随」与 AC-R4 #4 的「触摸路径逐字不变」同时成立。

### 决策 7：视觉指示零侵入 —— 只在「发生过键入」后画当前段描边

行为：抽屉本生命周期内 `hasKeyboardInput == false` 时**不画任何东西**（AC-R5 #1 逐像素一致的口径）；首次键入后，给当前段在**中间行位置**画一个 2px 主色圆角描边（`Stack` + `Positioned` + `IgnorePointer`，不占布局、不改变卡片高度、不拦截 CupertinoPicker 手势）。

为什么是描边而不是填充底：CupertinoPicker 自带 `selectionOverlay` 已是圆角浅灰底（`wheel_date_picker.dart:126-128` 一带的默认外观），再叠一层填充底会与该外观叠加成一坨。描边表达「输入焦点」的语义也更准确。

### 决策 8：键映射表下沉到桥，金额位改为引用（去重）

`_kAndroidKeyMap`（`amount_editor_sheet.dart:246-283`）与 `_kHardwareDigits`（`:217-238`）是金额位私有副本。本需求要同样的表，若再抄一份就是第三份（原生 `isCapturedKey` 是 Kotlin 侧的一份，天然无法共享，只能靠注释对齐 —— 该文件已有「与 Dart 侧 `_kAndroidKeyMap` 对齐」的注释，`MainActivity.kt:296`）。

做法：把映射表与 `LogicalKeyboardKey? logicalKeyFromAndroidKeyCode(int)` 移进 `lib/services/platform/hardware_key_bridge.dart`（桥的职责就是这条通路），金额位删除私有副本改为引用；`MainActivity.kt` 的 `isCapturedKey` 增补方向键，并保持注释互指。

### 决策 9：驱动抽成一个可复用件（一处实现，四处接入）

新增 `lib/widgets/ui/wheel_key_input.dart`，内容物：

| 类型 | 职责 |
|---|---|
| `WheelKeyColumn` | 段规格：`width`、`minOf()` / `maxOf()`（**回调**，因为日段上限随年月变）、`prefixMode`、`onApply(int)`（由宿主 widget 实现「设值 + 同步滚动」） |
| `WheelKeyInputController` | 段缓冲与当前段、三态列规则（决策 2）、退格（决策 4）、apply 转发；对外只暴露 `handleLogicalKey(key) → bool` 与 `activeIndex` / `hasKeyboardInput` |
| `WheelKeyInputMixin` | 把控制器接进 `State`：`initState` 注册双通路 + 捕获，`dispose` 成对撤销，按键转 `handleLogicalKey` |

四个抽屉各自只写「本抽屉有几段、各段值域、apply 落到哪个 setState + 哪个控制器」，不重复按键与缓冲逻辑。**不做抽象到 `PiggyPickerSheet` 的"万能外壳"**：外壳（`picker_sheet.dart:21-97`）是纯展示层，不知道内容语义；把键盘语义塞进去会让它对所有选择器（列表/网格/单选）都负上无关职责，且无法表达"段"。

### 决策 10：活动段跟随指针选中（2026-10-15 用户修正）

需求 R7：数字键要落进「用户刚点/滚的那一列」，不是永远从年段起算。

**用指针级 `Listener`，不用 `onSelectedItemChanged`**。理由是后者会被**非用户意图**的跳动触发：

- 键盘通路的 `jumpToItem`（决策 6）会触发它 —— 敲年段时月/日轮被 `_syncMonthWheel` / `_syncDayWheel` 联动跳位，活动段会被"偷"到月/日；
- 换句话说 `onSelectedItemChanged` 无法区分"用户滚的"与"程序同步的"，要挂就得再加一层 programmatic 跳动的守卫，复杂度不值当。

而 `Listener(onPointerDown + onPointerSignal)` 记录到的只有纯粹的用户意图：手指按下 / 鼠标点按 = 选中该列；`PointerScrollEvent`（鼠标滚轮滚列）也算选中。`Listener` 不参与手势竞技场，对 `CupertinoPicker` 的拖动 / 抛掷零干扰。

配套两点：

- `WheelKeyInputController` 增 `selectColumn(int)`：**无条件**清掉目标段键入缓冲（滚轮已把值改掉，旧前缀再粘新键位会得到怪值）。与 `moveTo` 的区别是 `moveTo` 在目标段相同时直接返回（键盘自动前进不能把已开始的缓冲清掉）。
- 四处重复的 `_keyFocus(index, picker)` 上收为 mixin 的具体方法（`keyColumn`），内部包 `Listener` + `WheelKeyActiveOverlay`，四处删掉自己那份。
- 描边口径不变（决策 7）：`active = hasKeyboardInput && activeIndex == index` —— 触摸选段**不**绘制描边，仍是"发生键盘键入后才出现"，但出现的位置跟着用户选中的列。这样 AC-R5 #1「零按键零影响」继续成立。

### 决策 11：描边包裹层结构必须恒定（2026-10-15 用户报障修正）

需求 R8：切列不得改写任何列的值。

**反例（踩过）**：`WheelKeyActiveOverlay.build` 曾按 `active` 在「直接 `return child`」与「包一层 `Stack`」之间切换（决策 7 的最初写法）。`Stack` 与 `CupertinoPicker` 是不同 widget 类型，同一插槽换类型时元素会被销毁重建 —— 该列的 `CupertinoPicker` 连同其 `Scrollable` 一起重建，重建后 `FixedExtentScrollController` 重新 attach 出一个以 `initialItem`（抽屉打开那一刻的值）为起点的 `position`。于是「敲完数字去点别的列」（描边从这一列退场，`active` true → false）会让本列滚轮**连同取值**悄悄退回初值：用户报障「月选 2 后点日，月变成 10」正是 `initialItem` = 10 月（打开时的月）的复现。

**修法**：`child` 永远待在 `Stack` 的首个插槽（`Positioned.fill`），只让描边这个**兄弟节点**随 `active` 增删 —— 子列表长度变化不影响首个子节点（无 key 的 `updateChildren` 按位匹配），滚轮元素与其 position 全程存活。

**尺寸口径不变**：`Stack` 只有定位子节点时 `RenderStack._computeSize` 取 `constraints.biggest`（`rendering/stack.dart:662`），与滚轮自身撑满的结果一致，AC-R5 #1「无键入时逐像素一致」继续成立（回归用例显式断言高度 156）。描边 `DecoratedBox` 仍只在 `active` 时存在，`find.byKey(borderKey)` 的「无描边」断言不受影响。

## 三、实现步骤

1. **RED 测试**：`test/widgets/wheel_key_input_test.dart`。以 `WheelDatePicker` / `WheelTimePicker` 为主靶（覆盖 AC-R1/R2/R3），`_DateStepPicker` / `_TimeStepPicker` 经 `showWheelDateTimePicker` 覆盖 AC-R2 #3 与"两步各自撤销捕获"；原生通道用例沿用既有 `sendNativeKey` 手法（`test/widgets/amount_editor_hardware_keys_test.dart:49-55`，用 `StandardMethodCodec` 直接灌 `handlePlatformMessage`）。
2. **映射表下沉**：`hardware_key_bridge.dart` 增 `kAndroidKeyMap` + `logicalKeyFromAndroidKeyCode`；`amount_editor_sheet.dart` 删私有副本改为引用（既有金额测试必须是绿的 —— 这步的回归由既有两个金额键盘测试守着）。
3. **原生侧**：`MainActivity.isCapturedKey` 增补方向键 `19/20/21/22`（不进 `TAB`）。
4. **驱动**：新增 `wheel_key_input.dart`（决策 9）。
5. **接入四处**：`WheelDatePicker`、`_DateStepPicker`、`_TimeStepPicker`、`WheelTimePicker` —— 每处先把「设值 + 滚动同步」抽成唯一 apply 方法（决策 6），再接驱动；`ym` / `y` 模式按存在的段给规格（`wheel_date_picker.dart:174` / `:214` 的段存在性判断）。
6. **视觉**：当前段描边（决策 7），`hasKeyboardInput` 由控制器暴露。
7. **回归**：`flutter analyze --fatal-infos` + 全量 `flutter test`；手动在 MuMu 上验 AC-R4 #2 / #3（金额位与抽屉同时存在、关闭后撤销捕获）。

## 四、边界条件与风险

| 风险 | 缓解 |
|---|---|
| **捕获未撤销 → 抽屉关闭后持续吞数字键** | `dispose` 成对撤销（决策 1）；新增用例断言「关闭抽屉后 `setCapture` 被置 false」（模拟通道可捕获 `setCapture` 调用参数） |
| **只注册框架层 → MuMu/投屏完全无效** | 双通路都注册；原生 keyCode 用例走 `sendNativeKey`，框架层用例走 `HardwareKeyboard`/`sendKeyEvent`，两条各有用例 |
| 与金额位抢键 | 复用 `route.isCurrent` 闸门；AC-R4 #2 显式断言「抽屉盖在记账表单上时金额位不变」 |
| 日段上限动态、`minDate` 裁剪后段起点非 1 | 段值域一律取当前**已裁剪列表**的 `first/last`（`wheel_date_picker.dart` 的 `_years / _monthsOf / _daysOf`，与 `build` 共用同一份计算）；AC-R1 #4 显式覆盖 |
| 键盘值与滚轮显示不一致 | 决策 6 的唯一 apply 入口 + AC-R1 #1 的「实时跟随」断言 |
| **包裹层结构随状态切换 → 滚轮元素重建、该列值回退初值** | 决策 11：`child` 固定在 `Stack` 首个插槽，只有描边兄弟节点增删；AC-R8 锁「切列不得改写列值」，并顺带断言滚轮尺寸不变 |
| 年段中间态不精确 | 如实登记（决策 3 / 需求风险 5），不为它加自定义渲染 |
| 触摸路径被改动 | 唯一 apply 入口是**同一份**逻辑，触摸回调改为调它；AC-R4 #4 用「不同按键 + 拖拽」对照，且 AC-R5 #1 锁「无键入时无描边」 |
| 无障碍回归 | 决策 5：`TAB` 不进原生捕获集合；抽屉的 X / √ 图标已有 `Semantics` 口径（`picker_sheet.dart` 头部的 `PiggySheetHeader`），本次不动 |
| 每列 apply 的 haptics | `PiggyHaptics.selection()` 只留在**触摸回调**里（`onSelectedItemChanged`），键盘通路不震 —— 连续 8 位键入不会连振 8 次。两通路共用同一份 `_apply*` 逻辑，只在 `syncWheel`（落位）与 haptics 上分流：触摸不跳自己那列（避免打断抛掷动量），键盘要跳（值变了轮子必须跟上） |

## 五、工作量拆解

| 块 | 内容 | 量级 |
|---|---|---|
| 映射表下沉 + 原生方向键 | 3 处小改（桥 / 金额位 / Kotlin） | 小 |
| 驱动 `wheel_key_input.dart` | 段规格 + 三态列规则 + 退格 + 切段 | 中（本需求的主体） |
| 接入四处 | 各抽屉抽 apply 唯一入口 + 接驱动 + `ym`/`y` 模式分支 | 中 |
| 当前段描边 | `Stack` 描边 + `hasKeyboardInput` 门控 | 小 |
| 测试 | AC-R1/R2/R3/R4/R5 约 20 例 | 中 |

主要不确定性集中在**年段中间态的观感**与**接入四处时 `ym`/`y` 模式的段裁剪**（`ym` 只接受 6 位、`y` 只接受 4 位），需实机（MuMu）确认后再收尾。
