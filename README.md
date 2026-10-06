# 小猪记账(PiggyCount) &nbsp; [English](README_EN.md)

<div align="center">

![GitHub stars](https://img.shields.io/github/stars/mecoren/PiggyCount?style=social)
![License](https://img.shields.io/badge/license-Business%20Source%20License-orange.svg)
![Release](https://img.shields.io/github/v/release/mecoren/PiggyCount?label=latest&color=green)
![Downloads](https://img.shields.io/github/downloads/mecoren/PiggyCount/total?color=blue)
![Last commit](https://img.shields.io/github/last-commit/mecoren/PiggyCount)
![Flutter](https://img.shields.io/badge/Flutter-3.47.6-02569B?logo=flutter)

**你的数据,你做主的开源记账应用**

支持 WebDAV / S3 两种自建云同步方案

<br/>

[🌐 官网](https://count.beejz.com) · [📖 文档](https://count.beejz.com/docs/intro) · [💝 捐赠](#-捐赠支持) · [💬 Telegram](https://t.me/piggycount) · [📦 APK](https://github.com/mecoren/PiggyCount/releases/latest) · [🚀 TestFlight](https://testflight.apple.com/join/Eaw2rWxa)

</div>

---

## 💡 为什么选择小猪记账

一款轻量、开源、隐私可控的**个人财务管理**和**支出追踪** App。

| 传统记账应用 | 小猪记账 |
|---|---|
| ❌ 数据存第三方,无法审计 | ✅ **完全开源**,代码可审计 |
| ❌ 隐私可能被分析利用 | ✅ **离线优先** + 自建云端,开发者无法访问 |
| ❌ 服务商倒闭数据丢失 | ✅ **数据主权**,自建云同步任选 |
| ❌ 高级功能付费墙 | ✅ **完全免费**(包括 AI 识别 / 语音记账) |
| ❌ 广告 / 理财推荐 | ✅ **零广告 / 零追踪 / 零数据收集** |

> **平台支持**:🤖 Android 7.0+（minSdk 24） · 🍎 iOS 15.5+
>
> ~~📱 HarmonyOS — [已停止更新](https://github.com/TNT-Likely/piggycount-openharmony)~~

---

## 🌟 核心功能

> **🔧 需配置** = 需要先完成一次性设置才能用（填 API Key、自建云端凭据或授予系统权限）；
> 未标注的功能开箱即用。各类配置说明见下方「功能启用条件」。

<details>
<summary><b>🤖 AI 智能记账</b> 🔧 需配置 — AI 对话 / 图片识别 / 语音 / 截图自动识别</summary>

- **AI 小助手** 🔧 — 自然语言对话记账,智能理解意图,基于智谱 GLM-4
  需在「设置 → AI 助手」填入智谱 API Key
- **拍照 / 截图识别记账** 🔧 — 识别支付宝/微信/云闪付截图与票据照片,由 AI 视觉模型
  (`glm-4v-flash`)完成,需智谱 API Key（无离线本地 OCR 引擎,v3.2.1 起已移除）
- **语音记账** 🔧 — 按住说话,GLM 模型理解口语化表达("今天买菜花了 50 块")
  需智谱 API Key
- **截图自动记账** 🔧 — Android 无障碍服务监听 / iOS 快捷指令双击背部触发
  Android 需在系统设置中授予无障碍权限;iOS 需从「快捷指令」导入配套指令

</details>

<details>
<summary><b>📝 基础记账</b> — 多账本 / 多账户 / 二级分类 / 预算 / 周期记账 / 标签 / 图表 / 导入导出</summary>

- **多账本** — 生活/工作/投资分开管理,每本独立币种
- **多账户** — 现金/银行卡/信用卡等独立账户,转账自动更新双方余额
- **二级分类** — 父子分类层级
- **预算管理** — 月度总预算 + 分类预算
- **周期记账** — 每日/每周/每月/每年自动记账,适合固定收支
- **标签系统** — 多标签 + 颜色标记,灵活筛选
- **图表分析** — 月度报表 / 分类排行 / 趋势分析 / 年度报告
- **数据导入导出** — CSV(支付宝/微信账单)+ YAML 配置导出

</details>

<details>
<summary><b>🎨 体验</b> 🔧 部分需配置 — 暗黑模式 / 多语言 / 桌面小组件 / 主题装扮</summary>

- **暗黑模式** — 纯黑 + 主题色边框,OLED 友好
- **多语言** — 官方简中 / 繁中 / English,社区贡献韩语,本地化日期/数字格式
- **桌面小组件** 🔧 — 6 类 × 12 种规格(收支速览/净资产/快速记账/预算/最近交易/仪表盘),暗黑/多语言/主题色全跟随,[全家福预览](#桌面小组件)
  需手动添加到桌面(iOS 在「今天」视图/主屏添加,Android 长按主屏 → 小组件)
- **主题装扮** — 多主题色

</details>

### 功能启用条件

| 功能 | 启用条件 | 配置位置 |
|---|---|---|
| AI 小助手 / 语音记账 / 拍照与截图识别 | 智谱 GLM API Key | 设置 → AI 助手 |
| 截图自动记账(Android) | 系统「无障碍」权限 | 系统设置 → 无障碍 |
| 截图自动记账(iOS) | 导入配套快捷指令 | 「快捷指令」App |
| 云同步(WebDAV / S3) | 自建服务地址 + 凭据 | [docs/cloud-setup.md](docs/cloud-setup.md) |
| 端到端加密同步 | 先配置云同步,再设置加密密码 | 设置 → 云同步 → 加密 |
| 桌面小组件 | 添加到桌面 | iOS 主屏 / Android 长按主屏 |
| 应用锁(生物识别) | 设备已录入指纹/面容 | 设置 → 隐私与安全 |
| 数据备份/恢复 | 无需配置(本地);云端备份同云同步 | — |


---

## 📸 截图预览

<div align="center">
  <img src="demo/videos/zh/01-add-transaction.gif" alt="快速记账" width="200" />
  <img src="demo/videos/zh/02-ocr-recognition.gif" alt="AI 截图识别记账" width="200" />
  <img src="demo/videos/zh/04-data-analysis.gif" alt="数据分析" width="200" />
</div>

### 桌面小组件

6 类内容 × 12 种规格,不打开 App 也能看账、一点直达记账:

<details>
<summary>查看桌面小组件全家福(6 类 × 12 规格)</summary>

<div align="center">
  <img src="demo/widgets/widgets-showcase-zh.png" alt="桌面小组件全家福:收支速览 / 净资产 / 快速记账 / 预算进度 / 最近交易 / 综合仪表盘" width="820" />
</div>

</details>

<details>
<summary>更多截图(9 大主题 / 暗黑模式)</summary>

### 9 大功能主题

<div align="center">
  <img src="preview/store-zh/01-home.png" alt="首页" width="200" />
  <img src="preview/store-zh/02-open-source.png" alt="云服务" width="200" />
  <img src="preview/store-zh/03-analytics.png" alt="数据分析" width="200" />
</div>

<div align="center">
  <img src="preview/store-zh/04-ai.png" alt="AI 智能记账" width="200" />
  <img src="preview/store-zh/05-add.png" alt="记一笔" width="200" />
  <img src="preview/store-zh/06-ledgers.png" alt="多账本" width="200" />
</div>

<div align="center">
  <img src="preview/store-zh/07-tags.png" alt="彩色标签" width="200" />
  <img src="preview/store-zh/08-accounts.png" alt="资产管理" width="200" />
  <img src="preview/store-zh/09-mine.png" alt="设置中心" width="200" />
</div>

### 暗黑模式

<div align="center">
  <img src="preview/dark/01-home.png" alt="首页-暗黑" width="200" />
  <img src="preview/dark/02-chart-analysis.png" alt="图表分析-暗黑" width="200" />
  <img src="preview/dark/04-profile.png" alt="我的-暗黑" width="200" />
  <img src="preview/dark/05-ai-chat.png" alt="AI对话-暗黑" width="200" />
</div>

</details>

---

## ☁️ 云同步方案

小猪记账提供 WebDAV / S3 两种自建同步方案,所有方案数据完全由你掌控,**详细配置教程见 [docs/cloud-setup.md](docs/cloud-setup.md)**。

| 方案 | 适用场景 | 特点 |
|---|---|---|
| **WebDAV** | NAS 用户 | 数据本地化、群晖/绿联云/Nextcloud |
| **S3 协议** | 灵活云存储 | Cloudflare R2 / AWS S3 / MinIO,免费额度大 |

> 🔐 **为什么自建?** 隐私第一、成本可控、数据安全、开源可审计。所有同步代码开源。

---

## 🛠️ 开发指南

<details>
<summary>技术栈 + 快速开始</summary>

### 技术栈

- **Flutter 3.47.6** · 跨平台 UI 框架（Android 侧 compileSdk 37 / AGP 9 / Gradle 9 / Kotlin 2.4）
- **Riverpod** · 状态管理
- **Drift (SQLite)** · 本地数据库 ORM
- **WebDAV / S3** · 云端同步多方案

### 快速开始

```bash
# 安装依赖
flutter pub get

# 代码生成（build_runner 2.15 起 --delete-conflicting-outputs 已移除，带上会被忽略）
dart run build_runner build

# 运行应用
flutter run --flavor dev

# 构建发布
flutter build apk --flavor prod --release
```

更多开发规范见 [docs/contributing/CONTRIBUTING_ZH.md](docs/contributing/CONTRIBUTING_ZH.md)。

</details>

---

## 🤝 贡献

<details>
<summary>欢迎所有形式的贡献</summary>

- 🐛 [报告 Bug](https://github.com/mecoren/PiggyCount/issues/new)
- 💡 [功能建议](https://github.com/mecoren/PiggyCount/discussions/new?category=ideas)
- 💻 [代码贡献](docs/contributing/CONTRIBUTING_ZH.md#代码贡献流程) · 🌍 [翻译](docs/contributing/CONTRIBUTING_ZH.md#翻译贡献) · 📝 [文档](docs/contributing/CONTRIBUTING_ZH.md#文档贡献) · 🎨 [设计师招募](docs/contributing/CONTRIBUTING_ZH.md#designer-recruitment)

**快速开始**:Fork → 创建 feature 分支 → 提交 → PR。详细规范见 [完整贡献指南](docs/contributing/CONTRIBUTING_ZH.md)。

</details>

---

## 🎨 皮肤

<details>
<summary>贡献一款顶部皮肤</summary>

「主题色 + 皮肤 = 顶部头图」。皮肤分**代码皮肤**(`CustomPainter` 画渐变 / 几何,跟随主题色)和**图片皮肤**(SVG,`BoxFit.cover` 铺满头部,可整幅染成主题色)两类。

最简单的方式:照着 [`example_skin.svg`](assets/header_skins/example_skin.svg) 画一张 SVG → 丢进 `assets/header_skins/` → 在 `lib/styles/header_skins.dart` 注册一条 → 加 i18n 名跑 `flutter gen-l10n`。

**完整规范(SVG 要求 + 主题色着色 + 接入步骤)见 [assets/header_skins/README.md](assets/header_skins/README.md)。**

</details>

---

## 💬 常见问题

<details>
<summary>查看常见问题解答</summary>

**Q: 不配置云服务能正常使用吗?**
A: 完全可以!应用默认本地存储,所有功能都能正常使用。可随时导出 CSV 备份。

**Q: 应该选哪个云方案?**
A:
- 跨平台、有免费云存储额度 → **S3 协议**(Cloudflare R2 / MinIO)
- 有 NAS → **WebDAV**

**Q: 如何确保数据安全?**
A: 使用自己的服务器 / Storage / Bucket,WebDAV 和 S3 建议 HTTPS 加密传输。

更多详情见 [docs/cloud-setup.md](docs/cloud-setup.md) 或 [Issues](https://github.com/mecoren/PiggyCount/issues)。

</details>

---

## 💝 捐赠支持

小猪记账完全免费开源,**无广告无付费功能**。如果觉得有用,请作者喝杯咖啡 ☕ 支持持续开发。

### 捐赠方式

[![PayPal](https://img.shields.io/badge/PayPal-Donate-0070BA?logo=paypal&logoColor=white&style=for-the-badge)](https://paypal.me/sunxiaoyes)

<details><summary>支付宝 / 微信二维码</summary>

| 支付宝 | 微信支付 |
|:---:|:---:|
| <img src="docs/donate/alipay.png" width="160" alt="支付宝"/> | <img src="docs/donate/wechat.png" width="160" alt="微信支付"/> |

</details>

**USDT (TRC20)**:`TKBV69B2AoU67p3vDhnJUbMJtZ1DxuUF5C` · <details><summary>币安二维码</summary>![币安](docs/donate/binance.png)</details>

### 资金透明度

| 项 | 金额 |
|---|---|
| Apple 开发者账号续费 | ¥688 / 年 |
| 轻量云服务器(ICP 备案) | ¥79 / 年 |
| 域名 | ¥80 / 年 |
| Google Play 开发者账号(一次性) | ¥177 |
| **年度持续成本** | **¥847 / 年** |

### 感谢支持者

| | | | | | | | | | | | | |
|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| <img src="assets/avatars/qiao.svg" width="44"/> | <img src="assets/avatars/rui.svg" width="44"/> | <a href="https://github.com/fishdivinity"><img src="assets/avatars/fishdivinity.png" width="44"/></a> | <img src="assets/avatars/shao.svg" width="44"/> | <img src="assets/avatars/ge.svg" width="44"/> | <img src="assets/avatars/te.svg" width="44"/> | <img src="assets/avatars/wen.svg" width="44"/> | <img src="assets/avatars/anon.svg" width="44"/> | <a href="https://github.com/birdnofoots"><img src="https://github.com/birdnofoots.png" width="44"/></a> | <a href="https://github.com/charieswang72-pro"><img src="https://github.com/charieswang72-pro.png" width="44"/></a> | <a href="https://github.com/542474846"><img src="https://github.com/542474846.png" width="44"/></a> | <a href="https://github.com/JOHN-2025"><img src="https://github.com/JOHN-2025.png" width="44"/></a> | <a href="https://github.com/HowcanoeWang"><img src="https://github.com/HowcanoeWang.png" width="44"/></a> |
| *桥 ¥12 | *睿 ¥720 | fishdivinity ¥100 | *邵 ¥15 | *哥 ¥6 | *特 ¥15 | *文 ¥50 | 匿名 ¥50 | birdnofoots ¥10 | Charies ¥10 | 542474846 ¥66 | JOHN-2025 ¥30 | 浩瀚猫 ¥98 |

> 💡 已捐赠?[提交信息](https://github.com/mecoren/PiggyCount/issues/new?template=donation_info.yml) 展示在列表中。

---

## 📄 开源协议

本项目采用 **商业源代码许可证(Business Source License,BSL)**。

| 用途 | 许可 |
|---|---|
| ✅ **个人使用 / 学习研究 / 开源贡献** | 完全免费 |
| ❌ **商业使用** | 需要付费授权 |

<details>
<summary>什么算商业使用</summary>

- 将本软件作为商业产品或服务提供给客户
- 在盈利性组织中使用本软件
- 基于本软件开发商业产品
- 提供基于本软件的付费云服务

商业授权价格与购买流程见 [COMMERCIAL_LICENSE.md](COMMERCIAL_LICENSE.md)，或邮件联系 **sunxiaoyes@outlook.com**。详见 [LICENSE](LICENSE)。

</details>

---

## 📦 相关仓库

| 仓库 | 说明 |
|---|---|
| [PiggyCount-Cloud](https://github.com/TNT-Likely/PiggyCount-Cloud) | 自建云同步服务端 + Web 管理端(FastAPI + React,实时协同已下线,历史项目) |
| [PiggyCount-Website](https://github.com/TNT-Likely/PiggyCount-Website) | 官网 / 文档仓库 |
| [piggycount-openharmony](https://github.com/TNT-Likely/piggycount-openharmony) | 鸿蒙版本(已停止更新) |
| [BeeShot](https://github.com/TNT-Likely/BeeShot) | App Store 截图生成器 |
| [honeycomb](https://github.com/TNT-Likely/honeycomb) | Claude Code 开发脚手架插件市场(本项目开发用的 skills/agents 集合) |

---

## ⭐ Star History

<details>
<summary>查看 Star 历史曲线</summary>

<a href="https://www.star-history.com/?repos=tnt-likely%2Fpiggycount&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=tnt-likely/piggycount&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=tnt-likely/piggycount&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=tnt-likely/piggycount&type=date&legend=top-left" />
 </picture>
</a>

</details>

---

## 🙏 致谢

感谢 [果核剥壳 - 互联网的净土](https://www.ghxi.com/)、[星之墨辰](https://mp.weixin.qq.com/s/HieVbKzpdUvnoaCa_9xjkA) 对本项目的宣传。

感谢所有为小猪记账项目贡献代码、提出建议和反馈问题的朋友们!

如有问题或建议,欢迎在 [Issues](https://github.com/mecoren/PiggyCount/issues) 中提出,或在 [Discussions](https://github.com/mecoren/PiggyCount/discussions) 中参与讨论。

**小猪记账 🐝 — 让记账变得简单而安全**
