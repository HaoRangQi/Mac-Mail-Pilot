# MailPilot Native — 规格与实现状态

> 2026-10-23 23:25 更新。原生 macOS App，SwiftUI + Liquid Glass。

## 1. 产品定义

一个**自用的原生邮件工作台**：不做账号、不做登录、不做收信——直接读 Apple Mail 已经同步到本地的内容，在其上做 AI 管理。发送借道「邮件」App 投递。

## 2. 已锁定的决策

| 决策 | 结论 | 影响 |
|---|---|---|
| 使用者 | 只有自己 | 不签名、不公证、不做授权引导，FDA 手动勾一次即可 |
| 分发 | 不上架 App Store | 不受沙盒限制，可以读 `~/Library/Mail` |
| 技术栈 | **全 Swift，不要 Python** | Python 版降级为"实现原理参考"，不再是运行时依赖 |
| MCP | 不保留 MCP 访问层 | 只借鉴其实现思路（AppleScript 发送、emlx 解析） |
| 未读状态 | **本期不做** | 列表不显示未读小红点，也不读私有 Envelope Index |
| 删除 | **永不自动**，必须人点二次确认；已实现：借道「邮件」App 移入账户废纸篓 | 实现方式与 Apple Mail MCP 一致（AppleScript），Mail 的索引与服务器同步更新，刷新不会复活 |
| 发送 | 两条路径都实现，实测后取舍 | mailto + AppleScript，后者可切"直接发送" |

## 3. 架构

```
┌─────────────────────────────────────────┐
│  MailPilot.app (单进程, SwiftUI)         │
│                                         │
│  RootView ── TopBar / Sidebar / List    │
│       │            / Reader / Compose   │
│       ▼                                 │
│  AppModel (ObservableObject)            │
│       │                                 │
│       ▼                                 │
│  MailStore 协议                          │
│   ├─ DemoStore      演示数据（当前）      │
│   └─ NativeStore    读 ~/Library/Mail   │
│       │                                 │
│  MailSender ── mailto / AppleScript     │
│  MailMutator ── AppleScript 删除        │
└─────────────────────────────────────────┘
```

关键点：`MailStore` 是协议，视图层不关心数据来自演示还是真实文件。接真实邮件时只换实现，界面零改动。

`MailMutator` 与 `MailSender` 同构：都不碰邮件存储，只通过 AppleScript 让「邮件」App 自己动手。删除的定位链是 账户名 → 邮箱名 → RFC 2822 Message-ID（与 Apple Mail MCP 服务器同一方案），Message-ID 由 `EmlxParser` 从头解析获得；账户名 / 邮箱名定位均有回退（地址匹配、全邮箱扫描、`delete` 失败改显式 `move` 到废纸篓）。

## 4. 当前实现状态

已完成：

- `Package.swift` + SPM 构建（无需 Xcode，`make run` 出 .app）
- 三栏界面：侧边栏、列表、阅读窗格，Liquid Glass 面板
- **侧边栏按账号分组**：个人收藏（所有收件箱/旗标/草稿/已发送）+ 智能邮箱（今天）+ 每个账号的收件箱/草稿/已发送/垃圾邮件，带角标；分组可折叠，折叠状态持久化
- **主题切换**：跟随系统 / 浅色 / 深色，顶栏按钮循环切换，选择持久化
- **AI 配置面板**（Cherry Studio 式）：多服务商（Ollama 本地 / OpenAI 兼容 / Anthropic，本地优先）、启用开关、API 地址（`/v1` 自动补齐 + 实际请求路径预览）
- **模型目录与选择**：同步后只存目录，由用户挑选；「只看对话模型」关键词过滤图像 / 语音 / 向量模型；手动添加模型（ID / 名称 / 分组 / 上下文窗口 / 最大输出）
- **多密钥管理**：每个服务商可存多条 API Key，支持标签、逐条启用、复制、编辑、删除、显隐；调用时按顺序尝试，401/403/429 自动换下一条；旧的单密钥配置自动迁移
- **模型检测弹窗**：选择模型 + 打码密钥 + 可编辑的检测对话（默认「你的模型信息是？数据截止日期是？」，可自行改写）+ 单模型检测 / 检测所有模型 + 结果列表
- **AI 功能层**（对标 Spark）：个性化（简介可一键生成 / 自定义指令）、写作与回复（语气 / 长度 / 学习写作风格 / 写作样本 / 快速回复）、翻译（35 种语言 + 搜索）；所有偏好按固定顺序拼进系统提示词，自定义指令优先级最高
- **浮动 AI 问答框**（⌘K）：按账号选择操作范围（所有账号 / 手动多选），对话历史持久化，支持单条删除、批量删除、清空
- **本地优先提示**：端点设置处提示推荐本地模型，选中 Ollama 时显示"邮件内容不出本机"
- **真实邮件接入**：`MailAccess` 检测完全磁盘访问权限，`NativeMailStore` 直读 `~/Library/Mail` 的 `.emlx`；`EmlxParser` 支持 RFC2047 中文标题、base64 / quoted-printable、multipart 取 text/plain- **首次启动引导**：未授权时弹出四步引导（打开系统设置 → 隐私与安全性 → 完全磁盘访问 → 重新检测），可"先用演示数据"跳过
- **设置项「权限管理」置于首位**：未授权的用户可在设置内完成授权，实时显示状态、账号/邮箱数量与权限边界说明
- **关于页**：设置的第四个 Tab（权限管理 / 模型服务 / AI 功能 / 关于），含数据来源、数据位置、隐私说明、打开数据目录；菜单「关于 MailPilot」会打开设置并跳到该 Tab
- AI 栏三个动作已接真实模型；未配置时回退到本地规则生成，并明确提示
- **发送双路**：`mailto` 打开撰写窗口；AppleScript 创建撰写窗口，可选"直接发送"
- **真实删除**：阅读页垃圾桶按钮 → 二次确认 → `MailMutator` 用 AppleScript 让「邮件」App 把邮件移入该账户的废纸篓。`.emlx` 随之移出原邮箱目录、Envelope Index 与 IMAP 服务器同步更新，刷新不会复活；弹框文案如实说明去向。首次执行需在系统弹窗中允许 MailPilot 控制「邮件」（隐私与安全性 → 自动化）
- 启动状态落盘 `~/Library/Application Support/MailPilot/status.txt`（store 模式 + FDA 状态），诊断文件 `diagnose.txt` 补充 rawName / 账户名 / 邮箱地址 / Message-ID，用于排查权限与定位问题
- 打包脚本 `scripts/build.sh`，输出 `build/MailPilot.app`（ad-hoc 签名）

部分完成 / 有已知缺陷：

- `NativeMailStore`：已可读取真实邮件，但**无未读状态**（`.emlx` 不存已读与旗标）、「所有旗标」恒空、搜索为扫描式（收件箱与归档各最近 400 封）、删除已落地：AppleScript 借道「邮件」App 移入账户废纸篓（0.2.3，实现细节见第 3 节），刷新不复活
- 账号命名：优先 `Accounts.plist` → 账户目录 plist → 从邮件头推断（已发送 From / Delivered-To / To），仍有账户回退为「账户 xxxxxx」

未完成：

- "按提示找邮件 → 确认批量处理"的完整交互（AI 目前只能回答，不能执行动作）
- 删除链路实测：用户重新授权 FDA 后验证（首次删除另有自动化授权弹窗）
- 附件保存、规则、归档、会话视图
- （可选）固定签名证书免除每次编译后重授权 FDA——用户已接受手动重新授权的工作方式，暂缓

## 5. 已知约束

1. **Command Line Tools 缺 `libSwiftUIMacros.dylib`**，所以 `@State` / `@Bindable` 编不过。当前全部改用 `ObservableObject` + `@StateObject` / `@EnvironmentObject`。要恢复 `@State` 和 SwiftUI Preview，必须装 Xcode。
2. **FDA 授权与签名绑定**：每次重新编译，cdhash 变化会导致授权失效，需要重新勾选。开发期建议固定输出路径。
3. **AppleScript 性能悬崖**：枚举几万封邮件会超时。读必须走磁盘索引，写才走脚本，且必须用 `whose({messageId: ...})` 精确定位。
4. **发送不落自己的"已发送"**：借道 Mail.app 后，发送记录只存在于 Mail 里，MailPilot 界面看不到。

## 6. 安全边界

- 删除：AI 可以找，**不能删**。必须人点确认。
- 发送：默认只打开撰写窗口，用户手动点发送；"直接发送"是显式开关。
- 无自动归档、无自动清理。所有写操作都是用户触发的。

## 7. 构建与运行

```bash
make run      # 编译 + 组装 .app + 启动
make verify   # 只编译，快速检查错误
make clean    # 删除构建产物
```

依赖：macOS 26+（Liquid Glass），Command Line Tools。
