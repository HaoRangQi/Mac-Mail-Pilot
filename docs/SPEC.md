# MailPilot Native — 规格与实现状态

> 2026-10-25 13:00 更新。原生 macOS App，SwiftUI + Liquid Glass。

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

`MailMutator` 与 `MailSender` 同构：都不碰邮件存储，只通过 AppleScript 让「邮件」App 自己动手。删除的定位链经实测收敛为：

- **账户**：`id of account`（UUID，对应 `~/Library/Mail/V10/<UUID>` 目录名）→ 显示名 → 邮箱地址 → 唯一账户
- **邮箱**：指定邮箱（`rawName`）→ 该账户下所有非空邮箱 → **全库按 Message-ID 扫描**（跳过空邮箱）
- **消息**：Message-ID 同时按**裸值**与**带尖括号**两种格式匹配（`whose (message id is bareId or message id is angleId)`）。Mail.app 的 `message id` 有时不带尖括号，RFC 2822 头里是 `<id@host>`，只比一种会永远匹配不到
- **动作**：`delete` → 显式 `move` 到 `account of m` 的废纸篓

Message-ID 由 `EmlxParser` 从头解析获得。找不到时会把该账户首封邮件的真实 `message id` 作为样本随错误返回，用于判断是格式差异还是邮件不在 Mail 索引里。

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
- **设置项「权限管理」置于首位**：未授权的用户可在设置内完成授权，实时显示状态、账号/邮箱数量与权限边界说明；**其中「控制「邮件」App」卡片可主动申请自动化权限**（`AEDeterminePermissionToAutomateTarget`），把系统弹框提前到设置页
- **关于页**：设置的第四个 Tab（权限管理 / 模型服务 / AI 功能 / 关于），含数据来源、数据位置、隐私说明、打开数据目录；菜单「关于 MailPilot」会打开设置并跳到该 Tab
- AI 栏三个动作已接真实模型；未配置时回退到本地规则生成，并明确提示
- **发送双路**：`mailto` 打开撰写窗口；AppleScript 创建撰写窗口，可选"直接发送"
- **真实删除**：阅读页垃圾桶按钮 → 二次确认 → `MailMutator` 用 AppleScript 让「邮件」App 把邮件移入该账户的废纸篓。`.emlx` 随之移出原邮箱目录、Envelope Index 与 IMAP 服务器同步更新，刷新不会复活；弹框文案如实说明去向。首次执行需在系统弹窗中允许 MailPilot 控制「邮件」（隐私与安全性 → 自动化）。**2026-10-24 实测通过**：native 模式下删除成功，邮件进入 Mail 废纸篓。定位链最终形态见第 3 节
- 启动状态落盘 `~/Library/Application Support/MailPilot/status.txt`（store 模式 + FDA 状态），诊断文件 `diagnose.txt` 补充 rawName / 账户名 / 邮箱地址 / Message-ID，用于排查权限与定位问题
- 打包脚本 `scripts/build.sh`，输出 `build/MailPilot.app`（ad-hoc 签名）
- **阅读页头部信息完整**：发件人 / **收件人 / 抄送 / 密送**四行分组（标签固定宽对齐，空组不渲染，多人显示「共 N 人」，悬停看完整列表，每行独立复制）；日期解析失败不再落到 `.distantPast`（会显示「1年1月1日」），改为 `.emlx` 文件 mtime
- **顶栏模型指示器**：常驻显示当前模型名 + 信任标记（本地=锁 / 可信=勾 / 不可信=黄），点击弹快速切换面板（搜索 + 按服务商分组 + 当前项打勾），底部直达模型服务设置
- **AI 结果按动作区分操作**：摘要 / 分类 / 翻译只给「复制」；草拟回复给「复制 / 编辑 / 存草稿 / 发送」，草稿可编辑后再交付
- **安全体系（第三方模型风险管理）**：
  - 信任体系：供应商级 `trusted`（默认不可信）+ 模型级 `modelTrust` 覆盖；判定链「本地恒可信 → 模型级 → 供应商级」
  - `TrustPolicy` 是唯一决策来源：动作 × 信任 → allow / redact / confirm / deny
  - `AppModel.requestAI()` 是唯一 AI 入口：查策略 → 脱敏 → 需确认则挂起 → 发送 → 还原
  - `Redactor` 脱敏：邮箱 / 手机号 / 身份证 / 银行卡 / IP / 金额 / 电话七类内置正则 + 用户自定义正则 + 关键字（纯文本），占位符 `⟨类型N⟩`，返回后按内存映射还原；映射表不落盘不进日志
  - 设置页「隐私与数据」：总开关、四个动作的处置选择、七条规则逐条开关、自定义规则增删改（带实时命中测试）、关键字编辑
  - 脱敏命中明细可见：AI 结果区显示「已脱敏 N 处：类型×n…」，展开逐条「占位符 ← 原始值」
  - 外发确认框可展开逐字检查实际发送的脱敏内容
- **AI 工具调用（tool calling）**：`MailTool` 8 个工具，权限三级（只读 / 写入 / 破坏性）；`AIService.chatWithTools` 实现 OpenAI 协议循环（上限 4 轮）。只读工具（搜索 / 读正文 / 列邮箱）与 `moveToTrash` 已开放，后者走 `withCheckedContinuation` 挂起等用户确认，取消也会告知模型；`markRead` / `setFlag` / `saveDraft` / `sendMessage` 未开放
- **「外观」设置页**（0.2.35）：主题、强调色（内置四色 + 系统调色盘，自选色深色模式自动提亮）、字体族（系统 / 圆体 / 衬线 / 等宽）、整体字号四档、列表密度、面板宽度、背景色斑强度、正文字号与行距；带实时预览与一键恢复默认
  - 342 处硬编码字号全部收口到 `Font.app()`，由 `UIState` 快照统一缩放；主题/布局只读快照，改设置经 store → `UIState` → `AppModel` 转发触发重绘
  - 设置面板改左侧竖排导航（6 个中文 Tab 用 segmented 会被系统撑到 900pt 顶出窗口）
- **窗口背景图**（0.2.35）：本地图片或 http/https 链接，可调模糊 / 压暗 / 铺法；图片落地到 `Application Support/MailPilot/background.img`；模糊用 CoreImage 预烘成位图缓存，大图先缩到 2560px
- **自绘细滚动条**（0.2.35）：系统滚动条在出现/消失时挤压内容宽度导致文字重排，改为 `.scrollIndicators(.never)` + 3pt 浮层胶囊，不参与布局，可拖动
- **阅读区增强**（0.2.35）：正文最大化（隐藏侧栏与列表，弹簧动画）、AI 结果整块折叠（内容不清空）、删除按钮移到动作行最前
- **翻译专用模型**（0.2.36）：翻译可单独指定服务商 + 模型，未指定则跟随主模型；`requestAI` 增加 `route` 参数，信任判定 / 脱敏决策 / 实际请求都用 route 里的 model
- **单封邮件安全开关**（0.2.36）：阅读页盾牌图标三态（模型可信 / 按策略脱敏 / 本封不脱敏），标记后该邮件在不可信模型上跳过脱敏与确认；按 Message-ID 存本地，隐私页有总览与一键清除
- **侧边栏按服务商归类**（0.2.37）：三层结构「服务商 → 账号 → 邮箱」，`MailService.detect(email:)` 按邮箱域名识别 Gmail / Outlook / iCloud / Yahoo / QQ / 网易 / 其他；服务商与账号都可折叠，折叠键分别为 `svc:<名>` 与账号 id
- **写邮件页 AI**（0.2.37）：主题行下方 AI 条，按意图起草正文；正文非空时切换为「AI 修稿」按意图改写全文。主题作为显式约束写进提示词防跑偏，不填主题则约束不出现。外发内容只有用户意图 + 主题（修稿时含当前正文），不可信模型仍脱敏但**不弹确认**——用户点「AI 起草」本身即明确外发意图，且邮件正文不在外发内容里
- **AI 问答浮层 AskBar**（0.2.37）：Markdown 渲染（`MarkdownText`，按行切块 + `AttributedString` 行内样式）、每条回答复制 / 重跑、最新提问可编辑后重跑、全屏展开、清空与删除标红。`MarkdownText` 的 `inline()` 返回 `some View`（`Text.textSelection` 不返回 Text）
- **AI 问答空响应自愈**（0.2.37）：reasoning 模型 `content` 为空时自动重试一次（`tool_choice: none` + 要求直接回答），仍空则抛 `AIError.emptyResponse(diagnostic)`，诊断含 finish_reason / 是否只思考 / completion_tokens；Anthropic `max_tokens` 提到 4096
- **邮件正文 HTML 渲染**（0.2.38）：阅读页新增 WKWebView 渲染管线，`EmlxParser` 保留 text/html 原文与带 Content-ID 的内联图片（读上限 800KB → 2MB）。三层防线：`HTMLSanitizer`（Swift 白名单，设计移植自 K-9 Mail，Apache-2.0）管结构与协议 → CSP meta（`default-src 'none'; img-src data:`）管零外联 → DOMPurify（`atDocumentStart` 注入，双许可）管 mXSS；任一环失败整体退回纯文本。链接策略：普通 http/https 直接开系统浏览器，四种危险特征（可见文字域名与实际目标不符 / `brand.com@evil.com` @ 伪装 / punycode 或西里尔希腊混用同形字 / 裸 IP）弹确认展示真实地址，`javascript:` 等危险协议降级为不可点文本。WKWebView 加固：nonPersistent data store、弹窗全掐死、导航 100% 经 App 拦截。cid 图片 App 侧转 data URI（魔法字节定格式，SVG 不认，≤2MB/张、≤30 张）。**域名判定必须从 href 原文解析**——`URL.host` 会把中文域名规范化成 punycode，直接用它会把所有中文域名误判为「易混淆编码」（实测踩坑）。正文字号经 zoom 整体缩放 + calc 补偿联动。方案调研与威胁模型见 `docs/邮件正文HTML渲染方案调研.md`
- **演示数据正规化**（0.2.38）：五个账号统一人设地址（清除 `me@` 与 example.com 占位）；iCloud 收件箱新增 HTML 演示邮件（cid logo + 正常外链 + 会被拦截的远程题图），演示模式下即可验证渲染全链路；0.2.39 扩充英 / 法 / 俄三封 HTML 演示邮件（五常国家语言全覆盖）
- **侧边栏账号行防重名**（0.2.38）：账号名与服务商同名时退回显示邮箱名前缀（真实用户也常把账号命名成 "Gmail"）
- **HTML 远程图片放行**（0.2.39）：外观设置新增三档策略（始终阻止 / 每次询问 / 总是加载）。放行也走 App 代理下载（`RemoteImageLoader`：ephemeral session、≤2MB/张、≤8MB/次、≤30 张、image/* + 魔法字节复核），转 data URI 后进 WebView——**CSP 不放开，WebView 始终零外联**。`HTMLSanitizer` 的 img src 协议白名单放行 http(s) 是故意的：由遍历层确定性地换占位并记录 URL 清单（白名单若提前剥掉 src 就拿不到 URL 了）

部分完成 / 有已知缺陷：

- `NativeMailStore`：已可读取真实邮件，但**无未读状态**（`.emlx` 不存已读与旗标）、「所有旗标」恒空、搜索为扫描式（收件箱与归档各最近 400 封）。0.2.35 修了三处「读不全」：纳入 `.emlx.partial`（Mail 未下载完的邮件）、排序改为「mtime 粗取 2× → 邮件头 Date 精排」（Mail 迁移会把 mtime 统一刷掉）、跳过 `[Gmail]` 这类容器邮箱。**仍未在真实数据上验证**——每次重签 FDA 失效，需要用户手动重新授权
- 账号命名：优先 `Accounts.plist` → 账户目录 plist → 从邮件头推断（已发送 From / Delivered-To / To），仍有账户回退为「账户 xxxxxx」
- API Key 仍存 `UserDefaults` 明文 plist（应迁 Keychain）；`baseURL` 未强制 HTTPS
- tool calling 仅支持 OpenAI 兼容协议（DeepSeek / Ollama 等），Anthropic 的 tools 格式不同

未完成：

- **AI 批量处理交互**：`moveToTrash` 已可被 AI 调用（带确认），但「按提示找邮件 → 确认批量处理」的完整体验还没做
- 附件保存、规则、归档、会话视图
- ~~**邮件正文渲染**~~（0.2.38 已实现，含 0.2.39 远程图片放行，见「已完成」节）
- **本地模型预检（方案B，已评估未实现）**：用本地小模型给邮件打「敏感度 1-10」，高分时把处置从 redact 升级为 confirm/deny。路线首选 macOS 26 的 Foundation Models（`LanguageModelSession`），次选 MLX Swift；llama.cpp 因 0.5B CPU 推理 10-20 token/s、1000 token 邮件要 1 分钟+，不适合交互场景。**小模型只打分、不改写正文**
- **补开工具**：`markRead` / `setFlag`（需扩展 `MailStore` 协议，可能要借道 AppleScript）、`saveDraft` / `sendMessage`
- **MCP Server**：把同一套 `MailTool` 用 MCP 协议导出，让外部客户端（Claude Desktop 等）连接。tool calling 是共用地基，此项是薄适配层
- **账户级隐私策略**：按账户（工作 / 个人 / 金融）限制能否使用第三方模型
- **审计日志**：记录外发的元数据（时间、模型、字符数、邮件 ID，不含正文），可查看 / 导出 / 清除

- （可选）固定签名证书免除每次编译后重授权（FDA 与自动化都受益）。用户目前接受手动重新授权，暂缓；若重启此项，注意上次失败的根因是 openssl 3 默认用 AES-256-CBC + SHA256 导出 PKCS12，macOS `security import` 不认——加 `-legacy`（或 `-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES`）可解决；证书还需带 `extendedKeyUsage=codeSigning` 才会被 `codesign` 识别

## 5. 已知约束

1. **Command Line Tools 缺 `libSwiftUIMacros.dylib`**，所以 `@State` / `@Bindable` 编不过。当前全部改用 `ObservableObject` + `@StateObject` / `@EnvironmentObject`。要恢复 `@State` 和 SwiftUI Preview，必须装 Xcode。
2. **FDA 授权与签名绑定**：每次重新编译，cdhash 变化会导致授权失效，需要重新勾选。开发期建议固定输出路径。
3. **AppleScript 性能悬崖**：枚举几万封邮件会超时。读必须走磁盘索引，写才走脚本，且必须用 `whose({messageId: ...})` 精确定位。
4. **发送不落自己的"已发送"**：借道 Mail.app 后，发送记录只存在于 Mail 里，MailPilot 界面看不到。
5. **自动化权限（控制「邮件」）与责任进程**：TCC 的 Apple Events 授权按「调用方 × 目标 App」逐对记录，且以**责任进程**为身份。从终端 `open` 启动时责任进程被判为 Terminal，于是弹框写「终端.app 想要控制 邮件.app」、授权也记在终端名下（实测 `AEDeterminePermissionToAutomateTarget` 对 终端→邮件 返回 `noErr`）。macOS **没有预授权入口**——系统设置里的自动化列表只显示已经触发过的配对，没弹过框的配对不在列表里。唯一主动申请方式是 `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: true)`，已接入权限管理页。要彻底稳定（重编译不掉授权），需要固定签名身份，见未完成项。

## 6. 安全边界

- 删除：AI **可以调用** `moveToTrash`，但必须人点确认才会执行（continuation 挂起等用户）；取消时会把「用户取消了这次操作」回传给模型，不让它自己编结果
- 发送：默认只打开撰写窗口，用户手动点发送；"直接发送"是显式开关
- 工具权限三级：只读任何模型可用；写入与破坏性一律确认
- 提示词层面禁止模型在收到「已执行」之前声称已删除 / 已发送
- 无自动归档、无自动清理。所有写操作都要用户点头。
- **第三方模型风险管理**：供应商默认不可信；不可信模型上，只读类动作自动脱敏，会产生对外内容的动作每次确认；脱敏规则与处置都可在「隐私与数据」页调整，命中明细对用户可见
- **单封邮件豁免**：用户可把某封邮件标记为「不敏感」，该邮件在不可信模型上原样发送（不脱敏、不确认）。豁免**只降级 redact / confirm，不推翻 deny**——「禁止该动作用于不可信模型」是对动作本身的硬性规定。三处可见性兜底：动作行图标常驻三态、AI 结果区提示「本次未脱敏」、隐私页可查看总数并一键清除

## 7. 构建与运行

```bash
make run      # 编译 + 组装 .app + 启动
make verify   # 只编译，快速检查错误
make clean    # 删除构建产物
```

依赖：macOS 26+（Liquid Glass），Command Line Tools。
