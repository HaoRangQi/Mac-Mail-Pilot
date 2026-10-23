# MailPilot Native — 规格与实现状态

> 2026-10-23 20:20 锁定。原生 macOS App，SwiftUI + Liquid Glass。

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
| 删除 | **永不自动**，AI 只负责找，人确认后才删 | 所有破坏性操作必须二次确认 |
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
└─────────────────────────────────────────┘
```

关键点：`MailStore` 是协议，视图层不关心数据来自演示还是真实文件。接真实邮件时只换实现，界面零改动。

## 4. 当前实现状态

已完成：

- `Package.swift` + SPM 构建（无需 Xcode，`./build.sh` 出 .app）
- 三栏界面：侧边栏、列表、阅读窗格，Liquid Glass 面板
- **侧边栏按账号分组**：个人收藏（所有收件箱/旗标/草稿/已发送）+ 智能邮箱（今天）+ 每个账号的收件箱/草稿/已发送/垃圾邮件，带角标
- **主题切换**：跟随系统 / 浅色 / 深色，顶栏按钮循环切换，选择持久化
- **AI 配置面板**（Cherry Studio 式）：多服务商（Ollama 本地 / OpenAI 兼容 / Anthropic，本地优先）、启用开关、API 地址（`/v1` 自动补齐 + 实际请求路径预览）、模型列表（同步 / 手动添加 / 选中 / 删除）
- **多密钥管理**：每个服务商可存多条 API Key，支持标签、逐条启用、复制、编辑、删除、显隐；调用时按顺序尝试，401/403/429 自动换下一条；旧的单密钥配置自动迁移
- **模型检测弹窗**：选择模型 + 打码密钥 + 可编辑的检测对话（默认「你的模型信息是？数据截止日期是？」，可自行改写）+ 单模型检测 / 检测所有模型 + 结果列表
- **AI 功能层**（对标 Spark）：个性化（简介可一键生成 / 自定义指令）、写作与回复（语气 / 长度 / 学习写作风格 / 写作样本 / 快速回复）、翻译（开关 + 目标语言）；所有偏好按固定顺序拼进系统提示词，自定义指令优先级最高
- **本地优先提示**：端点设置处提示推荐本地模型，选中 Ollama 时显示"邮件内容不出本机"
- **真实邮件接入**：`MailAccess` 检测完全磁盘访问权限，`NativeMailStore` 直读 `~/Library/Mail` 的 `.emlx`；`EmlxParser` 支持 RFC2047 中文标题、base64 / quoted-printable、multipart 取 text/plain
- **首次启动引导**：未授权时弹出四步引导（打开系统设置 → 隐私与安全性 → 完全磁盘访问 → 重新检测），可"先用演示数据"跳过
- AI 栏三个动作已接真实模型；未配置时回退到本地规则生成，并明确提示
- **发送双路**：`mailto` 打开撰写窗口；AppleScript 创建撰写窗口，可选"直接发送"
- **删除确认**：`confirmationDialog` 二次确认，确认后才真正移除
- 打包脚本 `build.sh`，输出 `build/MailPilot.app`（ad-hoc 签名）

未完成：

- `NativeStore`：读 `.emlx` + 自建索引（**下一步**，需要完全磁盘访问权限）
- "按提示找邮件 → 确认批量处理"的完整交互（目前只有单封删除确认）
- 附件保存、规则、归档、会话视图

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
cd MailPilotNative
./build.sh                  # 编译 + 组装 .app
open build/MailPilot.app
```

依赖：macOS 26+（Liquid Glass），Command Line Tools。
