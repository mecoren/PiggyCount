# PiggyCount 工程文档索引

> 文档版本：v1.0
> 最后更新：2026-07-25
> 作者：wait
> 信息源：d:\DevTools\project\PiggyCount\docoments\ 目录下全部 17 篇文档

---

## 📖 文档系列总览

本工程文档系统是 PiggyCount 项目的**面向开发者的工程化文档**，目标读者为：

- **新加入项目的开发者**（1 年以上编程经验）
- **需要理解系统全貌的工程师**
- **参与贡献的开源社区成员**
- **进行架构决策的技术负责人**

文档基于**项目源码**与**静态代码审查**整理，遵循严格的信息源优先级：

1. 本地代码（最高优先级）
2. 项目内配置文件（pubspec.yaml、build.gradle、AndroidManifest.xml 等）
3. 项目内文档（README.md、CONTRIBUTING_ZH.md、PRIVACY.md、DESIGN_TOKENS.md）
4. 代码注释
5. 推断与建议（明确标记 `[推断]` / `[建议方案]`）

---

## 📚 文档目录

### 第一部分：项目认知

#### [01. 项目总览](file:///d:/DevTools/project/PiggyCount/docoments/01-project-overview.md)

**内容**：项目背景、核心定位（隐私优先 + 离线优先）、技术选型、平台支持、核心功能矩阵、相关仓库（PiggyCount-Cloud / PiggyCount-Website 等）。

**适合读者**：所有新接触 PiggyCount 的开发者（必读）。

**关键收获**：理解 PiggyCount 是什么、解决什么问题、与同类应用的差异。

---

#### [02. 术语表](file:///d:/DevTools/project/PiggyCount/docoments/02-glossary.md)

**内容**：业务术语（账本/账户/分类/标签/预算/周期交易等）与技术术语（syncId/override 字段/LWW/Lazy prime 等）的中英文对照与定义。

**适合读者**：所有开发者（遇到不熟悉的术语时查阅）。

**关键收获**：消除业务与技术沟通歧义。

---

#### [03. 技术栈](file:///d:/DevTools/project/PiggyCount/docoments/03-tech-stack.md)

**内容**：60+ 依赖包分类详解（状态管理 / 数据存储 / 网络 / 云同步 / AI / 平台集成 / UI / 工具），Flutter / Dart SDK 版本要求，本地路径包（flutter_ai_kit / flutter_cloud_sync）说明。

**适合读者**：新开发者环境搭建前必读；评估依赖升级时参考。

**关键收获**：理解项目使用了哪些技术、为什么选这些技术。

---

### 第二部分：架构与模块

#### [04. 系统架构](file:///d:/DevTools/project/PiggyCount/docoments/04-system-architecture.md)

**内容**：五层架构（UI → Provider → Service → Repository → Data）、同步引擎旁路设计、模块依赖关系图、关键架构决策（为何 Repository 三层架构、为何 ChangeTracker 模式）。

**适合读者**：所有开发者（必读）。

**关键收获**：理解代码应放在哪一层、层间调用规则。

---

#### [05. 核心模块](file:///d:/DevTools/project/PiggyCount/docoments/05-core-modules.md)

**内容**：12 个核心模块详解（账本管理 / 交易管理 / 账户管理 / 分类 / 标签 / 预算 / 周期交易 / 附件 / AI 记账 / 云同步 / 通知提醒 / 数据导入导出），模块间交互关系。

**适合读者**：开发具体功能前参考。

**关键收获**：知道某功能在哪个模块、模块间如何协作。

---

#### [06. 数据同步与离线](file:///d:/DevTools/project/PiggyCount/docoments/06-data-sync-and-offline.md)

**内容**：四层同步架构（Provider 抽象 / Manager / SyncEngine / Riverpod）、5 种同步后端（PiggyCount Cloud / iCloud / Supabase / WebDAV / S3）、push/pull/fullPush/fullPull 流程、离线优先策略、ChangeTracker 设计、单飞锁、LookupCache、Lazy prime 优化。

**适合读者**：修改同步引擎前必读；理解离线优先架构时参考。

**关键收获**：理解 PiggyCount 最复杂的子系统如何工作。

---

### 第三部分：数据与接口

#### [07. 数据模型](file:///d:/DevTools/project/PiggyCount/docoments/07-data-model.md)

**内容**：21 张 Drift 表完整 ER 图、字段说明、索引设计、schemaVersion=31 的迁移策略、`*SyncIdOverride` 字段设计、local_changes / sync_state / sync_pull_errors 表的作用。

**适合读者**：修改数据库结构前必读；排查数据问题参考。

**关键收获**：理解数据如何存储、表间关系、迁移如何设计。

---

#### [08. API 与数据访问](file:///d:/DevTools/project/PiggyCount/docoments/08-api-and-data-access.md)

**内容**：三层 Repository 架构（抽象接口 / 本地实现 / 聚合委托）、Repository 公开 API 速查、Provider 注入方式、Stream 响应式查询、参数化查询规范。

**适合读者**：开发涉及数据库操作的功能前必读。

**关键收获**：知道如何正确访问数据，避免直连 DB。

---

#### [09. 错误处理](file:///d:/DevTools/project/PiggyCount/docoments/09-error-handling.md)

**内容**：CloudSyncException 异常层级、sync_pull_errors 表隔离设计、SQLite busy retry 机制、401 自动 refresh token、用户侧错误提示策略、错误恢复流程。

**适合读者**：处理同步/网络错误时参考。

**关键收获**：理解错误如何传播、如何恢复。

---

### 第四部分：质量保障

#### [10. 测试策略](file:///d:/DevTools/project/PiggyCount/docoments/10-testing-strategy.md)

**内容**：测试分层（单元 / Widget / 集成）、测试工具（mocktail / 内存数据库 / FakePiggyCountCloudProvider）、现有覆盖分析（57 文件 451 用例）、测试缺口识别、TDD 建议。

**适合读者**：编写测试前参考；评估代码质量时参考。

**关键收获**：知道如何为新功能写测试、当前测试覆盖情况。

---

#### [11. 性能优化](file:///d:/DevTools/project/PiggyCount/docoments/11-performance.md)

**内容**：数据库索引设计、后台 Isolate 执行、整页事务 + busy retry、LookupCache 消除 N+1、Lazy prime 优化、多层单飞锁、启动并行预加载、FlutterListView 惰性渲染、autoDispose 状态管理、图片附件优化。

**适合读者**：性能调优参考；评估改动影响时参考。

**关键收获**：理解项目已做的性能优化与待补充项。

---

#### [12. 安全机制](file:///d:/DevTools/project/PiggyCount/docoments/12-security.md)

**内容**：本地数据安全、应用锁（PIN/生物识别）、凭证存储、网络通信安全、AI 隐私保护、数据导出安全、权限管理、输入验证、开源审计性、隐私政策与实现不符问题汇总。

**适合读者**：处理敏感数据前必读；安全审计参考。

**关键收获**：理解项目安全机制现状与已知风险。

---

### 第五部分：工程实践

#### [13. 构建发布](file:///d:/DevTools/project/PiggyCount/docoments/13-build-release.md)

**内容**：CI/CD pipeline（GitHub Actions release.yml）、Android 多 flavor + ABI Splits + 签名注入、iOS 签名 + TestFlight 上传、产物命名规则、版本号管理、Google Play 上传、应用内 OTA 更新机制、GitHub 镜像加速。

**适合读者**：发布新版本前必读；排查构建问题参考。

**关键收获**：理解项目如何从代码到分发的完整流程。

---

#### [14. 日志规范](file:///d:/DevTools/project/PiggyCount/docoments/14-logging.md)

**内容**：LoggerService 单例设计、LogEntry 循环缓冲（2000 条）、SharedPreferences 持久化（48h 过期）、日志查看界面、日志级别使用规范、性能日志、更新模块日志、同步日志、第三方日志、反模式。

**适合读者**：添加日志前参考；调试问题参考。

**关键收获**：知道如何正确记录日志、日志如何查看。

---

#### [15. 开发规范](file:///d:/DevTools/project/PiggyCount/docoments/15-development-guidelines.md)

**内容**：开发环境、项目目录结构、代码风格（命名/格式化/import/空安全/注释）、五层架构分层规则、Riverpod 状态管理规范、Drift 数据库规范、Design Token 系统强制使用、UI 开发规范、国际化规范、同步引擎开发规范、测试规范、Git 提交规范（Conventional Commits 中文）、PR 流程、CI 检查、代码生成、翻译贡献、常见陷阱、Code Review 检查清单。

**适合读者**：所有新开发者**必读**；提交 PR 前自检参考。

**关键收获**：知道如何写出符合项目规范的代码。

---

#### [16. 已知问题](file:///d:/DevTools/project/PiggyCount/docoments/16-known-issues.md)

**内容**：按 P0/P1/P2/P3 优先级分级的所有已知问题，涵盖隐私政策不符、PIN 安全薄弱、SQLite 明文、网络通信风险、AI 隐私不足、性能瓶颈、测试缺口、代码质量、文档不一致、平台兼容性等。短期/中期/长期改进路线。

**适合读者**：项目维护者规划迭代参考；新开发者避坑参考。

**关键收获**：了解项目当前问题与改进方向。

---

#### [17. 版本演进](file:///d:/DevTools/project/PiggyCount/docoments/17-version-evolution.md)

**内容**：基于 schemaVersion 1→31 的完整迁移历史，重建项目从单设备基础功能 → 同步基础设施 → 共享账本与多币种的演进时间线。包含每个版本的设计决策、回填策略、历史教训（v23 移除运行时推导、v24 幂等 ALTER 必要性、v30 向后兼容设计）。

**适合读者**：理解架构决策背景参考；设计新数据库迁移参考。

**关键收获**：理解项目为何演进到当前形态、未来可能的方向。

---

## 🗺️ 阅读路径建议

### 路径一：新开发者入门（推荐顺序）

```
01 项目总览
  ↓
02 术语表（快速浏览，遇到术语回查）
  ↓
03 技术栈
  ↓
04 系统架构
  ↓
15 开发规范（重点）
  ↓
05 核心模块
  ↓
07 数据模型
  ↓
08 API 与数据访问
  ↓
14 日志规范
  ↓
10 测试策略
  ↓
开始动手开发
  ↓
按需查阅 06 / 09 / 11 / 12 / 13 / 16 / 17
```

### 路径二：架构理解

```
01 项目总览
  ↓
04 系统架构
  ↓
05 核心模块
  ↓
06 数据同步与离线（重点）
  ↓
07 数据模型
  ↓
17 版本演进（理解为何这样设计）
  ↓
11 性能优化
  ↓
12 安全机制
```

### 路径三：贡献者快速上手

```
01 项目总览
  ↓
15 开发规范（重点）
  ↓
03 技术栈 → 环境搭建
  ↓
10 测试策略
  ↓
13 构建发布
  ↓
16 已知问题（挑选感兴趣的 issue）
  ↓
开始贡献
```

### 路径四：安全审计

```
12 安全机制（重点）
  ↓
16 已知问题（P0/P1 严重问题）
  ↓
17 版本演进（安全机制演进）
  ↓
09 错误处理
  ↓
11 性能优化
```

### 路径五：性能调优

```
11 性能优化（重点）
  ↓
07 数据模型（索引设计）
  ↓
06 数据同步与离线（同步路径优化）
  ↓
08 API 与数据访问（Repository 模式）
  ↓
16 已知问题（性能瓶颈）
```

---

## 👥 适用读者矩阵

| 文档 | 新开发者 | 贡献者 | 架构师 | 维护者 | 安全审计 |
|---|:-:|:-:|:-:|:-:|:-:|
| 01 项目总览 | ⭐ | ⭐ | ⭐ | ⭐ | ⭐ |
| 02 术语表 | ⭐ | ⭐ | - | - | - |
| 03 技术栈 | ⭐ | ⭐ | - | - | - |
| 04 系统架构 | ⭐ | ⭐ | ⭐ | ⭐ | - |
| 05 核心模块 | ⭐ | ⭐ | ⭐ | - | - |
| 06 数据同步 | - | ⭐ | ⭐ | ⭐ | - |
| 07 数据模型 | ⭐ | ⭐ | ⭐ | ⭐ | - |
| 08 API 与数据访问 | ⭐ | ⭐ | - | - | - |
| 09 错误处理 | - | ⭐ | ⭐ | ⭐ | - |
| 10 测试策略 | ⭐ | ⭐ | - | ⭐ | - |
| 11 性能优化 | - | ⭐ | ⭐ | ⭐ | - |
| 12 安全机制 | - | - | ⭐ | ⭐ | ⭐ |
| 13 构建发布 | - | ⭐ | - | ⭐ | - |
| 14 日志规范 | ⭐ | ⭐ | - | - | - |
| 15 开发规范 | ⭐ | ⭐ | - | - | - |
| 16 已知问题 | - | ⭐ | ⭐ | ⭐ | ⭐ |
| 17 版本演进 | - | - | ⭐ | ⭐ | - |

⭐ = 推荐阅读，空白 = 可选阅读

---

## 📊 文档统计

| 指标 | 数值 |
|---|---|
| 文档总数 | 17 篇 |
| 总字数 | 约 60,000+ 字 |
| Mermaid 图表 | 50+ 个 |
| 代码示例 | 200+ 段 |
| 引用源码文件 | 100+ 个 |
| 信息缺口标记 | 30+ 处 |

---

## 🔍 信息缺口标记说明

文档中使用的标记含义：

| 标记 | 含义 | 使用场景 |
|---|---|---|
| `[推断]` | 基于代码静态分析的推测 | 缺少官方文档说明时的推断结论 |
| `[建议方案]` | 作者推荐的改进方案 | 针对已知问题提出的解决方案 |
| `[待补充]` | 信息缺失，需后续补充 | 项目未实现/未配置/未文档化的内容 |
| `[待确认]` | 信息可能存在偏差，需确认 | 基于不完整信息的初步结论 |

**所有信息缺口已在各文档第 N 节"信息缺口"中汇总**，便于项目维护者后续补充。

---

## 📝 文档维护

### 更新原则

1. **代码变更同步**：任何架构/数据模型/同步引擎变更必须同步更新对应文档
2. **新增问题登记**：新发现的问题添加到 [16-known-issues.md](file:///d:/DevTools/project/PiggyCount/docoments/16-known-issues.md)
3. **版本演进追加**：每次 schemaVersion 升级在 [17-version-evolution.md](file:///d:/DevTools/project/PiggyCount/docoments/17-version-evolution.md) 第 4 节追加
4. **信息缺口闭环**：`[待补充]` 标记的内容补充后需移除标记
5. **PR 同步**：重大 PR 应包含文档更新

### 贡献方式

发现文档错误或需要补充：

1. Fork 仓库
2. 创建 `docs/` 分支：`git checkout -b docs/improve-xxx`
3. 编辑对应 `.md` 文件
4. 提交 PR，标题格式：`docs: 改进 XXX 文档`

### 文档版本规范

- 每篇文档头部包含：`文档版本`、`最后更新`、`作者`、`信息源`
- 重大修改递增 `文档版本`（v1.0 → v1.1）
- 更新 `最后更新` 日期

---

## 📎 相关资源

### 项目内文档

- [README.md](file:///d:/DevTools/project/PiggyCount/README.md) — 项目介绍（中英双语）
- [README_EN.md](file:///d:/DevTools/project/PiggyCount/README_EN.md) — English README
- [PRIVACY.md](file:///d:/DevTools/project/PiggyCount/PRIVACY.md) — 隐私政策
- [LICENSE](file:///d:/DevTools/project/PiggyCount/LICENSE) — BSL 许可证
- [docs/contributing/CONTRIBUTING_ZH.md](file:///d:/DevTools/project/PiggyCount/docs/contributing/CONTRIBUTING_ZH.md) — 贡献指南（中文）
- [docs/contributing/CONTRIBUTING_EN.md](file:///d:/DevTools/project/PiggyCount/docs/contributing/CONTRIBUTING_EN.md) — Contribution Guide (English)
- [docs/design/DESIGN_TOKENS.md](file:///d:/DevTools/project/PiggyCount/docs/design/DESIGN_TOKENS.md) — Design Token 完整对照表
- [docs/cloud-setup.md](file:///d:/DevTools/project/PiggyCount/docs/cloud-setup.md) — 云同步配置教程
- [docs/cloud-setup_EN.md](file:///d:/DevTools/project/PiggyCount/docs/cloud-setup_EN.md) — Cloud Setup Guide
- [docs/donate/README_ZH.md](file:///d:/DevTools/project/PiggyCount/docs/donate/README_ZH.md) — 捐赠说明
- [assets/header_skins/README.md](file:///d:/DevTools/project/PiggyCount/assets/header_skins/README.md) — 皮肤贡献规范
- [lib/ai/README.md](file:///d:/DevTools/project/PiggyCount/lib/ai/README.md) — AI 模块说明

### 外部资源

- **官网**：[https://count.beejz.com](https://count.beejz.com)
- **文档站**：[https://count.beejz.com/docs/intro](https://count.beejz.com/docs/intro)
- **GitHub 仓库**：[https://github.com/mecoren/PiggyCount](https://github.com/mecoren/PiggyCount)
- **GitHub Issues**：[https://github.com/mecoren/PiggyCount/issues](https://github.com/mecoren/PiggyCount/issues)
- **GitHub Discussions**：[https://github.com/mecoren/PiggyCount/discussions](https://github.com/mecoren/PiggyCount/discussions)
- **Telegram 群**：[https://t.me/piggycount](https://t.me/piggycount)
- **TestFlight**：[https://testflight.apple.com/join/Eaw2rWxa](https://testflight.apple.com/join/Eaw2rWxa)

### 相关仓库

| 仓库 | 说明 |
|---|---|
| [PiggyCount-Cloud](https://github.com/TNT-Likely/PiggyCount-Cloud) | 自建云同步服务端 + Web 管理端（FastAPI + React） |
| [PiggyCount-Website](https://github.com/TNT-Likely/PiggyCount-Website) | 官网 / 文档仓库 |
| [piggycount-openharmony](https://github.com/TNT-Likely/piggycount-openharmony) | 鸿蒙版本（已停止更新） |
| [BeeShot](https://github.com/TNT-Likely/BeeShot) | App Store 截图生成器 |
| [honeycomb](https://github.com/TNT-Likely/honeycomb) | Claude Code 开发脚手架插件市场 |

---

## 📋 文档清单（速查）

| 编号 | 文档 | 主要关键词 |
|---|---|---|
| 01 | [项目总览](file:///d:/DevTools/project/PiggyCount/docoments/01-project-overview.md) | 项目背景、核心定位、平台支持 |
| 02 | [术语表](file:///d:/DevTools/project/PiggyCount/docoments/02-glossary.md) | 业务术语、技术术语、中英对照 |
| 03 | [技术栈](file:///d:/DevTools/project/PiggyCount/docoments/03-tech-stack.md) | Flutter、Riverpod、Drift、依赖包 |
| 04 | [系统架构](file:///d:/DevTools/project/PiggyCount/docoments/04-system-architecture.md) | 五层架构、同步引擎、模块依赖 |
| 05 | [核心模块](file:///d:/DevTools/project/PiggyCount/docoments/05-core-modules.md) | 12 个模块、模块交互 |
| 06 | [数据同步与离线](file:///d:/DevTools/project/PiggyCount/docoments/06-data-sync-and-offline.md) | 四层同步、5 种后端、push/pull、单飞锁 |
| 07 | [数据模型](file:///d:/DevTools/project/PiggyCount/docoments/07-data-model.md) | 21 张表、ER 图、迁移策略 |
| 08 | [API 与数据访问](file:///d:/DevTools/project/PiggyCount/docoments/08-api-and-data-access.md) | Repository 三层、API 速查 |
| 09 | [错误处理](file:///d:/DevTools/project/PiggyCount/docoments/09-error-handling.md) | 异常层级、sync_pull_errors、401 refresh |
| 10 | [测试策略](file:///d:/DevTools/project/PiggyCount/docoments/10-testing-strategy.md) | 测试分层、mocktail、覆盖率 |
| 11 | [性能优化](file:///d:/DevTools/project/PiggyCount/docoments/11-performance.md) | 索引、Isolate、LookupCache、Lazy prime |
| 12 | [安全机制](file:///d:/DevTools/project/PiggyCount/docoments/12-security.md) | 应用锁、凭证存储、AI 隐私、网络通信 |
| 13 | [构建发布](file:///d:/DevTools/project/PiggyCount/docoments/13-build-release.md) | CI/CD、多 flavor、签名、OTA |
| 14 | [日志规范](file:///d:/DevTools/project/PiggyCount/docoments/14-logging.md) | LoggerService、级别规范、持久化 |
| 15 | [开发规范](file:///d:/DevTools/project/PiggyCount/docoments/15-development-guidelines.md) | 代码风格、Design Token、PR 流程 |
| 16 | [已知问题](file:///d:/DevTools/project/PiggyCount/docoments/16-known-issues.md) | P0-P3 分级、改进路线 |
| 17 | [版本演进](file:///d:/DevTools/project/PiggyCount/docoments/17-version-evolution.md) | schemaVersion 1→31、迁移模式 |

---

## 🎯 快速入口

### 我是新开发者，从哪开始？

→ 阅读 [01 项目总览](file:///d:/DevTools/project/PiggyCount/docoments/01-project-overview.md) → [15 开发规范](file:///d:/DevTools/project/PiggyCount/docoments/15-development-guidelines.md)

### 我想修改同步引擎

→ 阅读 [06 数据同步与离线](file:///d:/DevTools/project/PiggyCount/docoments/06-data-sync-and-offline.md) → [09 错误处理](file:///d:/DevTools/project/PiggyCount/docoments/09-error-handling.md) → [11 性能优化](file:///d:/DevTools/project/PiggyCount/docoments/11-performance.md)

### 我想添加新数据库表

→ 阅读 [07 数据模型](file:///d:/DevTools/project/PiggyCount/docoments/07-data-model.md) → [08 API 与数据访问](file:///d:/DevTools/project/PiggyCount/docoments/08-api-and-data-access.md) → [17 版本演进](file:///d:/DevTools/project/PiggyCount/docoments/17-version-evolution.md) 第 6 节迁移模式

### 我想提交 PR

→ 阅读 [15 开发规范](file:///d:/DevTools/project/PiggyCount/docoments/15-development-guidelines.md) → [10 测试策略](file:///d:/DevTools/project/PiggyCount/docoments/10-testing-strategy.md) → [13 构建发布](file:///d:/DevTools/project/PiggyCount/docoments/13-build-release.md)

### 我想了解安全机制

→ 阅读 [12 安全机制](file:///d:/DevTools/project/PiggyCount/docoments/12-security.md) → [16 已知问题](file:///d:/DevTools/project/PiggyCount/docoments/16-known-issues.md)

### 我想发布新版本

→ 阅读 [13 构建发布](file:///d:/DevTools/project/PiggyCount/docoments/13-build-release.md)

### 我想了解项目历史

→ 阅读 [17 版本演进](file:///d:/DevTools/project/PiggyCount/docoments/17-version-evolution.md)

---

## 📌 文档约定

### 文件命名

- 格式：`<两位编号>-<英文名>.md`
- 编号：01-17（按阅读顺序）
- 英文名：kebab-case

### 文档结构（8 段式）

每篇文档遵循统一结构：

1. **背景** — 为什么需要这份文档
2. **核心概念** — 关键术语速查表
3. **整体架构/流程** — Mermaid 图表展示
4. **详细设计** — 按模块/章节展开
5. **关键代码与位置** — 文件链接 + 代码片段
6. **使用规范** — 如何正确使用
7. **常见陷阱与最佳实践** — 避坑指南
8. **信息缺口** — `[待补充]` / `[待确认]` / `[推断]` / `[建议方案]` 标记

### Mermaid 图表规范

- 架构图用 `flowchart TB` 或 `flowchart LR`
- 时序图用 `sequenceDiagram`
- ER 图用 `erDiagram`
- 时间线用 `timeline`
- 关键节点使用 `<br/>` 换行
- 颜色填充用 `style` 注解

### 代码引用规范

- 文件引用：`[文件名](file:///绝对路径)` 或 `[文件名:行号](file:///绝对路径#L123-L145)`
- 代码块：使用三反引号 + 语言标识（dart / yaml / sql / mermaid / bash）
- 不在代码块中包含行号

---

## 🔄 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| v1.0 | 2026-07-25 | 初始版本，包含 17 篇文档 |

---

本文档作为 PiggyCount 工程文档系列的**入口与索引**，建议开发者收藏并定期查阅更新。如发现文档错误或需要补充，欢迎通过 PR 贡献。
