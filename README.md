# MailPilot

本地优先的 macOS 邮件客户端：直读「邮件」App 已同步到本机的数据，接入自己的 LLM 做摘要、草拟、分类、翻译和跨账号问答。

**没有后端，没有账号登录，邮件不出本机。**

## 环境要求

- macOS 26+
- Command Line Tools（`xcode-select --install`）
- 无需安装 Xcode

## 快速开始

```bash
make run      # 编译 + 打包 + 启动
```

或者分步：

```bash
make build    # 产出 build/MailPilot.app
open build/MailPilot.app
```

首次启动会弹出「完全磁盘访问权限」引导，按提示去
`系统设置 → 隐私与安全性 → 完全磁盘访问权限` 勾选 MailPilot 即可读取真实邮件。
未授权前会以演示数据运行，功能可正常体验。

## 常用命令

| 命令 | 作用 |
|---|---|
| `make run` | 构建并启动 |
| `make build` | 只构建打包 |
| `make verify` | 只编译，快速检查编译错误 |
| `make clean` | 删除 `.build/` 与 `build/` |

## 目录结构

```
MailPilotNative/
├── Makefile               # make run / build / verify / clean
├── Package.swift          # SwiftPM 配置（executableTarget）
├── Resources/
│   └── Info.plist         # Bundle 信息（含本地化声明）
├── Sources/MailPilot/
│   ├── App.swift          # @main + 菜单命令
│   ├── AppModel.swift     # @MainActor 状态中心、AI 调用编排、AI 历史
│   ├── Models.swift       # Message / Mailbox / Account / MailStore / DemoStore
│   ├── MailAccess.swift   # 完全磁盘访问权限检测与跳转
│   ├── NativeMailStore.swift  # 直读 ~/Library/Mail 的 .emlx
│   ├── EmlxParser.swift   # 轻量 MIME 解析（RFC2047 / base64 / QP / multipart）
│   ├── AISettings.swift   # 服务商与多密钥管理、AI 调用
│   ├── AIPreferences.swift # 个性化 / 语气 / 样本 / 翻译偏好
│   ├── MailSender.swift   # 通过「邮件」App 发信
│   └── Views/             # SwiftUI 界面
├── docs/
│   └── SPEC.md            # 需求与实现现状
├── scripts/               # build / run / clean
└── build/                 # 打包产物（已 gitignore）
```

## 架构

```
┌──────────────┐      ┌───────────────┐      ┌──────────────┐
│   Views      │ ───▶ │   AppModel    │ ───▶ │  MailStore   │
│ (SwiftUI)    │      │  @MainActor   │      │  protocol    │
└──────────────┘      └───────────────┘      └──────┬───────┘
                                                    │
                          ┌─────────────────────────┴──────────────┐
                          ▼                                        ▼
                   DemoStore（演示数据）              NativeMailStore（真实 .emlx）
```

- `MailStore` 是数据源协议，`AppModel` 只依赖协议，因此演示/真实可随时切换
- `NativeMailStore` 不做全量索引：列表按 mtime 取最近 N 封只解析头部，正文按需解析
- AI 层与服务商配置解耦，支持多密钥轮换（401/403/429 自动换下一条）

## 已知限制

- 未读状态不可用（`.emlx` 不存旗标与已读标记）
- 「所有旗标」恒为空
- 搜索为扫描式（收件箱与归档各最近 400 封），非全文索引
- 删除走「邮件」App，本地不直接删文件
- **每次重新编译都会改变 ad-hoc 签名，「完全磁盘访问权限」需要重新授权**
  （长期方案是固定签名证书）

## 推送与协作

```bash
git remote add origin <你的仓库地址>
git push -u origin main
```

提交前建议：

```bash
make verify    # 确认编译通过
```

## License

尚未选定。如需开源，在 `LICENSE` 中补充协议文本。
