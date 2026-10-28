# MailPilot Native — 规格与实现状态

> 2026-10-28 更新。原生 macOS App，SwiftUI + Liquid Glass。

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
┌──────────────────────────────────────────────────────┐
│  MailPilot.app (单进程, SwiftUI)                      │
│                                                      │
│  RootView ── TopBar / Sidebar / List                 │
│       │            / Reader / Compose                │
│       ▼                                              │
│  AppModel (ObservableObject)                         │
│       │                                              │
│       ├─ AI 通路 ── GuardedMailStore ──┐              │
│       │      （上锁过滤，数据层丢弃）    │              │
│       │                                ▼              │
│       └─ 界面通路 ──────────────► MailStore 协议       │
│                                    ├─ DemoStore      │
│                                    └─ NativeMailStore │
│                                         │            │
│                              MailIndex（SQLite+FTS5） │
│                              缓存，可随时重建          │
│                                                      │
│  MailSender ── mailto / AppleScript                  │
│  MailMutator ── AppleScript 删除 / 标已读 / 旗标       │
└──────────────────────────────────────────────────────┘
```

关键点：`MailStore` 是协议，视图层不关心数据来自演示还是真实文件。接真实邮件时只换实现，界面零改动。

**AI 通路多一层装饰器**（0.2.41）：`GuardedMailStore` 包住真实 store，上锁的邮件在这里被丢掉——模型不是「被告知别提」，而是根本拿不到。这层只作用于 AI，界面照常显示全部邮件（人自己要看的东西不该被藏）。过滤逻辑只写一遍，以后新增工具只要走这个 store 就自动受保护。

**索引是缓存，不是真相源**（0.2.42）：`MailIndex` 存元数据与 FTS 全文索引，`path + mtime + size` 三元组决定是否需要重新解析。索引文件删掉、结构不匹配，都只是下次启动慢一点——上锁与豁免的记录存在别处（UserDefaults），丢不了。

`MailMutator` 与 `MailSender` 同构：都不碰邮件存储，只通过 AppleScript 让「邮件」App 自己动手。三个写动作（删除 / 标已读 / 旗标）共用同一段定位脚本：

- **账户**：`id of account`（UUID，对应 `~/Library/Mail/V10/<UUID>` 目录名）→ 显示名 → 邮箱地址 → 唯一账户
- **邮箱**：指定邮箱（`rawName`）→ 该账户下所有非空邮箱 → **全库按 Message-ID 扫描**（跳过空邮箱）
- **消息**：Message-ID 同时按**裸值**与**带尖括号**两种格式匹配（`whose (message id is bareId or message id is angleId)`）。Mail.app 的 `message id` 有时不带尖括号，RFC 2822 头里是 `<id@host>`，只比一种会永远匹配不到
- **动作**：`delete` → 显式 `move` 到 `account of m` 的废纸篓；`set read status` / `set flagged status` 直接改属性

Message-ID 由 `EmlxParser` 从头解析获得。找不到时会把该账户首封邮件的真实 `message id` 作为样本随错误返回，用于判断是格式差异还是邮件不在 Mail 索引里。

## 4. 当前实现状态

已完成：

- `Package.swift` + SPM 构建（无需 Xcode，`make run` 出 .app）
- 三栏界面：侧边栏、列表、阅读窗格，Liquid Glass 面板
- **侧边栏按账号分组**：个人收藏（所有收件箱/旗标/草稿/已发送）+ 智能邮箱（今天）+ 每个账号的收件箱/草稿/已发送/垃圾邮件，带角标；分组可折叠，折叠状态持久化
- **主题切换**：跟随系统 / 浅色 / 深色，顶栏按钮循环切换，选择持久化
- **AI 配置面板**（Cherry Studio 式）：多服务商（Ollama 本地 / OpenAI 兼容 / Anthropic，本地优先）、启用开关、API 地址（`/v1` 自动补齐 + 实际请求路径预览）
- **Ollama 内置**（0.2.44）：供应商列表里恒有一个「Ollama 本地」，用户不用自己新建，也删不掉（不想用可以关开关）。判定看 `kind` 而不是 id——老配置里已有的 Ollama 保留原 id（翻译路由存的是 id），直接被认成内置。「添加服务商」里也不再提供 Ollama
  - **列表置顶靠渲染层**（0.2.46 / 0.2.47）：设置页 `displayProviders` 与顶栏切换面板 `selectableGroups` 都把内置项排到最前，`providers` 数组顺序不动——那是 `activeProvider` 的优先级，`selectModel` 会按用户选择重排；启动时强行前插会把用户选定的云端模型顶掉
  - **不预置模型**（0.2.46）：模型列表留空，点「同步模型」从 `/api/tags` 拉真实列表。之前预置的 `qwen2.5:7b` 只是猜的，多半没装
- **本地模型默认可信、可关闭**（0.2.45）：`trusted` 未表态时本地按可信、第三方按不可信；信任开关对本地也显示，关掉后本地模型同样走脱敏 + 确认。本地服务商详情页底部有「推荐模型」（`minicpm-v-4.7-1b-heretic`，1B / 约 672 MB），可一键加入列表，并按同步结果解析实际 tag（`ollama pull` 下来的是 `:q4_k_m` 之类，写不带 tag 的名字会打到 `:latest` 上报错）
- **模型目录与选择**：同步后只存目录，由用户挑选；「只看对话模型」关键词过滤图像 / 语音 / 向量模型；手动添加模型（ID / 名称 / 分组 / 上下文窗口 / 最大输出）
- **多密钥管理**：每个服务商可存多条 API Key，支持标签、逐条启用、复制、编辑、删除、显隐；调用时按顺序尝试，401/403/429 自动换下一条；旧的单密钥配置自动迁移
- **模型检测弹窗**：选择模型 + 打码密钥 + 可编辑的检测对话（默认「你的模型信息是？数据截止日期是？」，可自行改写）+ 单模型检测 / 检测所有模型 + 结果列表
- **AI 功能层**（对标 Spark）：个性化（简介可一键生成 / 自定义指令）、写作与回复（语气 / 长度 / 学习写作风格 / 写作样本 / 快速回复）、翻译（35 种语言 + 搜索）；所有偏好按固定顺序拼进系统提示词，自定义指令优先级最高
- **浮动 AI 问答框**（⌘K）：按账号选择操作范围（所有账号 / 手动多选），**按时间范围限定取件窗口**（0.2.48：今日 / 近三天 / 更多，默认今日；「更多」给起止日期，默认最近 7 天）。两项都由 `AskScopeStore` 在数据层执行，不是提示词约定（0.2.53）。对话历史持久化，支持单条删除、批量删除、清空
- **本地优先提示**：端点设置处提示推荐本地模型，选中 Ollama 时显示"邮件内容不出本机"
- **真实邮件接入**：`MailAccess` 检测完全磁盘访问权限，`NativeMailStore` 直读 `~/Library/Mail` 的 `.emlx`；`EmlxParser` 支持 RFC2047 中文标题、base64 / quoted-printable、multipart 取 text/plain
- **首次启动引导**：未授权时弹出四步引导（打开系统设置 → 隐私与安全性 → 完全磁盘访问 → 重新检测），可"先用演示数据"跳过
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
- **草稿可多轮改写（0.2.57）**：草拟回复的输出卡下方多一条「让它改」输入行——写一句要求（「再短一点」「语气更客气」）回车即改写，留空就是润色。改写复用 `requestAI` 的完整链路（脱敏 / 确认 / 审计），只是把当前草稿作为 `previousOutput` 带进 `PendingAIRequest`：**失败、被拒绝、用户取消、未配置模型时都原样放回旧稿**，不会因为一次改写把手里那份冲掉。手工编辑保存后的文本同样算「当前草稿」
- **安全体系（第三方模型风险管理）**：
  - 信任体系：供应商级 `trusted` + 模型级 `modelTrust` 覆盖；判定链「模型级 → 供应商级」。供应商级**未表态**时按类型取默认：本地可信（数据不出本机）、第三方不可信。本地这一档可以关掉（0.2.45），关掉后本地模型同样脱敏并确认
  - `TrustPolicy` 是唯一决策来源：动作 × 信任 → `Decision`。**决策是两个正交维度**（`redaction` 是否脱敏 × `confirmation` 是否确认），组合出放行 / 脱敏后放行 / 每次确认 / 脱敏后确认 / 禁止五种；不要退回四选一枚举
  - `AppModel.requestAI()` 是唯一 AI 入口：查策略 → 脱敏（**system 与 user 一起**，共用一套占位符编号）→ 需确认则挂起 → 发送 → 还原
  - 总开关「只要用不可信模型，一律先问我」只**追加确认**，不取消动作级已设的脱敏
  - `Redactor` 脱敏：邮箱 / 手机号 / 身份证 / 银行卡 / IP / 金额 / 电话七类内置正则 + 用户自定义正则 + 关键字（纯文本），占位符 `⟨类型N⟩`，返回后按内存映射还原；映射表不落盘不进日志
  - 设置页「隐私与数据」：总开关、五个动作（摘要 / 草拟 / 分类 / 翻译 / 问答）的处置选择、七条规则逐条开关、自定义规则增删改（带实时命中测试）、关键字编辑
  - 脱敏命中明细可见：AI 结果区显示「已脱敏 N 处：类型×n…」，展开逐条「占位符 ← 原始值」
  - 外发确认框可展开逐字检查实际发送的内容（system 与 user 都露出），并提供「脱敏后发送」——用户常是看到确认框才想起这封邮件敏感，不该逼他去改永久策略
- **AI 工具调用（tool calling）**：`MailTool` 9 个工具，权限三级（只读 / 写入 / 破坏性）；`AIService.chatWithTools` 支持 OpenAI / Anthropic / Ollama 三种协议（上限 4 轮）。**Ollama 有三处形状不同**（0.2.52 实测修正）：消息在顶层 `message` 而不是 `choices[0].message`；`function.arguments` 是对象不是 JSON 字符串；工具结果必须用 `tool_name` 回传，只给 `tool_call_id` 会让模型重复调同一个工具直到轮数耗尽。**工具集按模型信任级别下发**（`agentTools(trusted:)`）：可信/本地模型拿到全部 9 个；不可信模型只有 `searchMessages` / `getMessage` / `listMailboxes` / `moveToTrash`（挂起等确认）/ `sendMessage`（永远确认 + 收件人受限 + 正文不回补）/ `proposeBatch`。`markRead` / `setFlag` / `saveDraft` 这三个写入类**根本没下发给不可信模型**，模型凭记忆发出来也会被拒
  - **轮数用尽要软着陆**（0.2.55）：小模型会一路调工具把 4 轮耗光，原来直接报错等于把前几轮的成果全扔了。最后一轮**不下发 `tools`** 并明说「别调了，直接根据已查到的信息回答」，同时把沿途每轮的正文留着兜底；最后一轮若模型仍凭记忆发出工具调用，**不执行**（没有下一轮，执行只会白改数据）。报错信息带上每轮调了哪些工具。Ollama 请求体带 `keep_alive: "30m"`（闲置 5 分钟就卸载权重，一次提问只该付一次加载代价），本地超时单独放宽到 180s
  - 「4 轮都在调工具」**不是**模型没加载导致的：实测冷启动 `load_duration` 3ms、单轮往返 1–2 秒。模型没加载只会变慢，不会凭空返回 `tool_calls`
- **「外观」设置页**（0.2.35）：主题、强调色（内置四色 + 系统调色盘，自选色深色模式自动提亮）、字体族（系统 / 圆体 / 衬线 / 等宽）、整体字号四档、列表密度、面板宽度、背景色斑强度、正文字号与行距；带实时预览与一键恢复默认
  - 342 处硬编码字号全部收口到 `Font.app()`，由 `UIState` 快照统一缩放；主题/布局只读快照，改设置经 store → `UIState` → `AppModel` 转发触发重绘
  - 设置面板改左侧竖排导航（6 个中文 Tab 用 segmented 会被系统撑到 900pt 顶出窗口）
- **窗口背景图**（0.2.35）：本地图片或 http/https 链接，可调模糊 / 压暗 / 铺法；图片落地到 `Application Support/MailPilot/background.img`；模糊用 CoreImage 预烘成位图缓存，大图先缩到 2560px
  - **总开关 `backgroundEnabled`（0.2.58）**：关掉只是不渲染图片、退回默认色斑，`backgroundPath` / 模糊 / 压暗 / 铺法全部保留，随时可再打开。它是独立字段而不是复用 `backgroundPath = ""`——「移除」是真删缓存文件，两者语义不同。旧配置缺这个键时按 `true` 解（已经设了图的人不该升级后突然看不见图）
- **自绘细滚动条**（0.2.35）：系统滚动条在出现/消失时挤压内容宽度导致文字重排，改为 `.scrollIndicators(.never)` + 3pt 浮层胶囊，不参与布局，可拖动
- **阅读区增强**（0.2.35）：正文最大化（隐藏侧栏与列表，弹簧动画）、AI 结果整块折叠（内容不清空）、删除按钮移到动作行最前
- **翻译专用模型**（0.2.36）：翻译可单独指定服务商 + 模型，未指定则跟随主模型；`requestAI` 增加 `route` 参数，信任判定 / 脱敏决策 / 实际请求都用 route 里的 model
- **单封邮件安全开关**（0.2.36）：阅读页盾牌图标三态（模型可信 / 按策略脱敏 / 本封不脱敏），标记后该邮件在不可信模型上跳过脱敏与确认；按 Message-ID 存本地，隐私页有总览与一键清除
- **邮件与账号上锁**（0.2.41）：`MailGuard` 两级作用域（账号级 + 邮件级，取最严），按 Message-ID 存。`GuardedMailStore` 装饰器在**数据层**丢掉锁定邮件——模型不是「被告知别提」，而是根本拿不到；锁同时是写锁，`moveToTrash` 一并拒绝。`TrustPolicy.decide` 加 `protection` 参数，单封 AI 动作直接 deny 且不能被豁免绕过。失效记录按 20 天 TTL 清理（`missingSince` 为时钟，邮件重新出现则自动复活）。`sendMessage` 工具落地：永远人工确认、收件人默认锁到原发件人、正文不回补占位符。AI 输出链接纳入 `LinkPolicy`。详见 CHANGELOG 0.2.41
- **AskBar 脱敏 + 审计日志**（0.2.42）：`AIAction.ask` 纳入 `TrustPolicy`；`RedactionContext` 是会话级的，system / 问题 / 每次工具返回共用一套占位符编号，回答返回后还原并在气泡下显示命中统计。`AuditLog` 追加写 JSONL（5MB × 3 轮转），只记元数据不记正文，隐私页可查看大小 / 定位 / 清空
- **本地索引 `index.sqlite`**（0.2.42）：缓存库，`path + mtime + size` 判定是否需要重新解析；搜索改用 FTS5 trigram，覆盖全部邮件而非「每箱最近 400 封」，短于 3 字符退回 LIKE。索引打不开或结构不匹配就整份重建并退回现场解析。附件元数据（`partIndex` + 估算大小）、线程根（`References` 第一个）一并入库
- **附件保存**（0.2.42）：解析只收元数据不读字节，保存时按 `partIndex` 回原文件取；`NSSavePanel` 选路径、文件名剥路径分隔符与 `..`、保存后不自动打开
- **写工具补齐**（0.2.42）：`MailMutator` 定位链抽成共用块，删除 / 标已读 / 旗标共用；`saveDraft` 接线。**写入类工具只给可信模型**
- **会话视图**（0.2.43）：列表按线程聚合（最新一封 + 「N 封」角标），阅读页顶部有会话栏可切换；搜索时不聚合
- **Anthropic 工具调用**（0.2.43）：`chatWithTools` 分出 Anthropic 分支（顶层 `system` + `tool_use` / `tool_result` 内容块），工具定义自动转换，脱敏钩子两条路径一致
- **AI 批量处理**（0.2.43）：`proposeBatch` 工具 + 勾选清单 sheet。锁定邮件在解析阶段被丢弃、不会进清单；不可信模型只能批量删除；单次上限 50 封
- **仓库内断言测试**（0.2.43）：`make test` 跑 63 条断言，全部用合成 `.emlx`，不依赖 XCTest 与磁盘权限
- **侧边栏按服务商归类**（0.2.37）：三层结构「服务商 → 账号 → 邮箱」，`MailService.detect(email:)` 按邮箱域名识别 Gmail / Outlook / iCloud / Yahoo / QQ / 网易 / 其他；服务商与账号都可折叠，折叠键分别为 `svc:<名>` 与账号 id
- **写邮件页 AI**（0.2.37）：主题行下方 AI 条，按意图起草正文；正文非空时切换为「AI 修稿」按意图改写全文。主题作为显式约束写进提示词防跑偏，不填主题则约束不出现。外发内容只有用户意图 + 主题（修稿时含当前正文），不可信模型仍脱敏但**不弹确认**——用户点「AI 起草」本身即明确外发意图，且邮件正文不在外发内容里。**正文非空时留空也能点**（0.2.56）：那就是一键润色，提示词写死「不改原意与信息量，保留称呼、数字、日期和承诺，不新增不省略」——「改写」类指令最容易顺手加戏或删承诺，边界必须写进提示词
- **AI 问答浮层 AskBar**（0.2.37 / 0.2.54）：Markdown 渲染（`MarkdownText.parse` 按行切块 → `MarkdownRenderer` 拼成一份 `NSAttributedString`）、每条回答复制 / 重跑、最新提问可编辑后重跑、全屏展开、清空与删除标红。**整段回答由一个 `NSTextView`（`SelectableTextView`）承载**——SwiftUI 的 `Text` 一段一个可选区，列表里每条都是独立 `Text`，跨行选中做不到。版式（列表悬挂缩进、代码块底色、引用竖线）由 `NSParagraphStyle` 还原，字号仍读 `UIState`。提问气泡同样 `textSelection(.enabled)`，外层手势用 `simultaneousGesture` 以免吃掉拖选
- **问答范围（账号 + 时间）**（0.2.48 / 0.2.49 / 0.2.50 / 0.2.51 / 0.2.53）：范围是**数据层**属性，不是提示词建议，也不是每个工具自己的选项。`AskScopeStore` 叠在 `GuardedMailStore` 外面，`search` / `message` / `messages` / 三个写操作统一按「选中账号 + 时间窗口」收口——窗口外的邮件按 ID 也读不到、删不掉。多取几轮再收口（上限 400 条），因为选了「今日」时绝大多数命中都在窗口外。系统提示词写明范围；`listMailboxes` 在有窗口时不报整箱总数；气泡底部显示范围与**本轮实际读到的不同邮件数**（`AskTurn.scanned`），这是范围生效的唯一可见证据。上界取「那天的结束」，否则选到今天会漏掉今天收到的邮件。四个档位：忽略（`askWindow` 为 nil，不限时间）/ 今日（默认）/ 近三天 / 更多（自定义，默认最近 7 天）。0.2.53 起问答只剩一条路径——旧的直连上下文 `ask()` 已删除，建议按钮同样走 `askWithTools`
- **AI 问答空响应自愈**（0.2.37）：reasoning 模型 `content` 为空时自动重试一次（`tool_choice: none` + 要求直接回答），仍空则抛 `AIError.emptyResponse(diagnostic)`，诊断含 finish_reason / 是否只思考 / completion_tokens；Anthropic `max_tokens` 提到 4096
- **邮件正文 HTML 渲染**（0.2.38）：阅读页新增 WKWebView 渲染管线，`EmlxParser` 保留 text/html 原文与带 Content-ID 的内联图片（读上限 800KB → 2MB）。三层防线：`HTMLSanitizer`（Swift 白名单，设计移植自 K-9 Mail，Apache-2.0）管结构与协议 → CSP meta（`default-src 'none'; img-src data:`）管零外联 → DOMPurify（`atDocumentStart` 注入，双许可）管 mXSS；任一环失败整体退回纯文本。链接策略：普通 http/https 直接开系统浏览器，四种危险特征（可见文字域名与实际目标不符 / `brand.com@evil.com` @ 伪装 / punycode 或西里尔希腊混用同形字 / 裸 IP）弹确认展示真实地址，`javascript:` 等危险协议降级为不可点文本。WKWebView 加固：nonPersistent data store、弹窗全掐死、导航 100% 经 App 拦截。cid 图片 App 侧转 data URI（魔法字节定格式，SVG 不认，≤2MB/张、≤30 张）。**域名判定必须从 href 原文解析**——`URL.host` 会把中文域名规范化成 punycode，直接用它会把所有中文域名误判为「易混淆编码」（实测踩坑）。正文字号经 zoom 整体缩放 + calc 补偿联动。方案调研与威胁模型见 `docs/邮件正文HTML渲染方案调研.md`
- **演示数据正规化**（0.2.38）：五个账号统一人设地址（清除 `me@` 与 example.com 占位）；iCloud 收件箱新增 HTML 演示邮件（cid logo + 正常外链 + 会被拦截的远程题图），演示模式下即可验证渲染全链路；0.2.39 扩充英 / 法 / 俄三封 HTML 演示邮件（五常国家语言全覆盖）
- **侧边栏账号行防重名**（0.2.38）：账号名与服务商同名时退回显示邮箱名前缀（真实用户也常把账号命名成 "Gmail"）
- **HTML 远程图片放行**（0.2.39）：外观设置新增三档策略（始终阻止 / 每次询问 / 总是加载）。放行也走 App 代理下载（`RemoteImageLoader`：ephemeral session、≤2MB/张、≤8MB/次、≤30 张、image/* + 魔法字节复核），转 data URI 后进 WebView——**CSP 不放开，WebView 始终零外联**。`HTMLSanitizer` 的 img src 协议白名单放行 http(s) 是故意的：由遍历层确定性地换占位并记录 URL 清单（白名单若提前剥掉 src 就拿不到 URL 了）
- **外发策略修正**（0.2.40）：`TrustPolicy.Decision` 从四选一枚举改为 **`redaction` × `confirmation` 两个正交维度**（+ `denial`）——原先「要确认」必然等于「不脱敏」，类型上就不存在「先脱敏再确认」。总开关 `alwaysConfirmUntrusted` 改为**只追加确认、不取消脱敏**（原实现直接 `return .confirm`，把动作级「脱敏后放行」降级成原样外发）。草拟回复 / 翻译默认改为「脱敏后确认」——它们的外发输入和摘要完全一样（整封正文）。确认框在未脱敏时提供「脱敏后发送」，不必为一次操作去改永久策略。**system 提示词纳入脱敏**（含「我的简介」与发件箱原文样本）：`Redactor` 新增多段入口，system 与 user 共用一套占位符编号，否则还原会把 A 段的邮箱写进 B 段
- **应用图标**（0.2.40）：`scripts/make-icon.swift` 用 CoreGraphics 直绘 7 个尺寸（非等比缩小），苔绿圆角方 + 米白信封 + 金色星芒，星在后信在前；`build.sh` 走 iconset → iconutil → 拷进 bundle

部分完成 / 有已知缺陷：

- `NativeMailStore`：已可读取真实邮件，但**无未读状态**（`.emlx` 不存已读与旗标）、「所有旗标」恒空。0.2.42 起列表与搜索走本地 `index.sqlite`（FTS5 trigram，覆盖全部邮件；索引不可用时回退现场解析）。0.2.35 修了三处「读不全」：纳入 `.emlx.partial`（Mail 未下载完的邮件）、排序改为「mtime 粗取 2× → 邮件头 Date 精排」（Mail 迁移会把 mtime 统一刷掉）、跳过 `[Gmail]` 这类容器邮箱。**仍未在真实数据上验证**——每次重签 FDA 失效，需要用户手动重新授权
- 账号命名：优先 `Accounts.plist` → 账户目录 plist → 从邮件头推断（已发送 From / Delivered-To / To），仍有账户回退为「账户 xxxxxx」
- API Key 仍存 `UserDefaults` 明文 plist（应迁 Keychain，用户已明确本期不做）；`baseURL` 未强制 HTTPS
- tool calling 两套协议都已实现（0.2.43 补 Anthropic）

未完成：

- ~~**AI 批量处理交互**~~（0.2.43 已实现 `proposeBatch` + 勾选清单）
- ~~**会话视图 UI**~~（0.2.43 已实现列表聚合与阅读页会话栏）
- **未读状态 / 旗标读取**：`.emlx` 不存旗标，需要读 Mail 的 `Envelope Index`（私有 SQLite）。写侧已通（`markRead` / `setFlag` 走 AppleScript），读侧缺数据源
- **规则与归档**：完全没有
- ~~**附件保存**~~（0.2.42 已实现，见「已完成」节）
- ~~**邮件正文渲染**~~（0.2.38 已实现，含 0.2.39 远程图片放行，见「已完成」节）
- **本地模型预检（方案B，已评估未实现）**：用本地小模型给邮件打「敏感度 1-10」，高分时把处置从 redact 升级为 confirm/deny。路线首选 macOS 26 的 Foundation Models（`LanguageModelSession`），次选 MLX Swift；llama.cpp 因 0.5B CPU 推理 10-20 token/s、1000 token 邮件要 1 分钟+，不适合交互场景。**小模型只打分、不改写正文**
- ~~**补开工具**~~（0.2.42 已开放 `markRead` / `setFlag` / `saveDraft`，写入类只给可信模型）
- **MCP Server**：把同一套 `MailTool` 用 MCP 协议导出，让外部客户端（Claude Desktop 等）连接。真正的障碍是 GUI App 不能对外提供 stdio，需要拆包成 `MailPilotCore` + `mailpilot-mcp` CLI
- ~~**审计日志**~~（0.2.42 已实现，JSONL + 5MB × 3 轮转，隐私页可查看 / 清空）
- **账户级隐私策略**：账号级上锁已覆盖「这个账号的邮件能不能给不可信模型看」；仍缺的是「本地模型 / 可信第三方」分档（例如某些邮件只允许本地模型）

- （可选）固定签名证书免除每次编译后重授权（FDA 与自动化都受益）。用户目前接受手动重新授权，暂缓；若重启此项，注意上次失败的根因是 openssl 3 默认用 AES-256-CBC + SHA256 导出 PKCS12，macOS `security import` 不认——加 `-legacy`（或 `-macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES`）可解决；证书还需带 `extendedKeyUsage=codeSigning` 才会被 `codesign` 识别

## 5. 已知约束

1. **Command Line Tools 缺 `libSwiftUIMacros.dylib`**，所以 `@State` / `@Bindable` 编不过。当前全部改用 `ObservableObject` + `@StateObject` / `@EnvironmentObject`。要恢复 `@State` 和 SwiftUI Preview，必须装 Xcode。
2. **FDA 授权与签名绑定**：每次重新编译，cdhash 变化会导致授权失效，需要重新勾选。开发期建议固定输出路径。
3. **AppleScript 性能悬崖**：枚举几万封邮件会超时。读必须走磁盘索引，写才走脚本，且必须用 `whose({messageId: ...})` 精确定位。
4. **发送不落自己的"已发送"**：借道 Mail.app 后，发送记录只存在于 Mail 里，MailPilot 界面看不到。
5. **自动化权限（控制「邮件」）与责任进程**：TCC 的 Apple Events 授权按「调用方 × 目标 App」逐对记录，且以**责任进程**为身份。从终端 `open` 启动时责任进程被判为 Terminal，于是弹框写「终端.app 想要控制 邮件.app」、授权也记在终端名下（实测 `AEDeterminePermissionToAutomateTarget` 对 终端→邮件 返回 `noErr`）。macOS **没有预授权入口**——系统设置里的自动化列表只显示已经触发过的配对，没弹过框的配对不在列表里。唯一主动申请方式是 `AEDeterminePermissionToAutomateTarget(..., askUserIfNeeded: true)`，已接入权限管理页。要彻底稳定（重编译不掉授权），需要固定签名身份，见未完成项。

## 6. 安全边界

- 删除：AI **可以调用** `moveToTrash`，但必须人点确认才会执行（continuation 挂起等用户）；取消时会把「用户取消了这次操作」回传给模型，不让它自己编结果。批量走 `proposeBatch` 的勾选清单（0.2.43），不逐封弹框——连点 N 次确认框会让人无脑点
- 发送：撰写页默认只打开「邮件」撰写窗口，用户手动点发送（"直接发送"是显式开关）；**AI 调用 `sendMessage` 则永远弹确认**，且确认框里能改收件人、能看见完整正文
- 工具权限三级：只读任何模型可用；写入与破坏性一律确认。**写入类（`markRead` / `setFlag` / `saveDraft`）只给可信模型**，不可信模型的工具集只有 读 + 删（进废纸篓）+ 发（永远确认）+ 批量删
- 提示词层面禁止模型在收到「已执行」之前声称已删除 / 已发送
- 无自动归档、无自动清理。所有写操作都要用户点头。
- **第三方模型风险管理**：供应商默认不可信；不可信模型上**五个动作默认都含脱敏**——只读类（摘要 / 分类 / 问答）脱敏后直接发，会产生对外内容的（草拟回复 / 翻译）脱敏后再确认。脱敏规则与处置都可在「隐私与数据」页调整，命中明细对用户可见
- **已知缺口**：AskBar 的管控已在 0.2.42 补齐（脱敏走会话级 `RedactionContext`）。仍未接入的是**未读状态**——`.emlx` 不存旗标，需要读 Mail 的 `Envelope Index` 私有 SQLite，无法在无 FDA 环境验证，暂不盲写
- **单封邮件豁免**：用户可把某封邮件标记为「不敏感」，该邮件在不可信模型上原样发送（不脱敏、不确认）。豁免**只降级 redact / confirm，不推翻 deny**——「禁止该动作用于不可信模型」是对动作本身的硬性规定。三处可见性兜底：动作行图标常驻三态、AI 结果区提示「本次未脱敏」、隐私页可查看总数并一键清除
- **上锁**（0.2.41）：与豁免方向相反，是**访问控制**而不是脱敏策略。上锁的账号 / 邮件在非可信模型上根本拿不到（`GuardedMailStore` 在数据层丢弃），阅读页 AI 动作直接 deny。两级取最严、账号锁不可被单封解锁、豁免与锁冲突时锁优先
  - **问答范围也要过锁**（0.2.59）：账号胶囊是按侧边栏选中项自动填的，所以上锁账号很容易被带进问答。现在 `runAsk` 用 `MailAccessScope.canRead(accountID:)` 过滤用户选的账号集合——全被过滤掉时直接回一句「已上锁，当前模型不可信」，部分被过滤时弹 toast 说明只查了其余账号。**范围里剩下的账号名才写进 system 提示词**，否则模型会知道一个它根本读不到的账号存在。胶囊里上锁账号显示锁图标且点不动
- **发送永远人工确认**：可信模型也一样。风险不在投递而在内容——模型能把读到的邮件发出去，这是唯一的外泄通道。非可信模型下收件人默认锁到原发件人，正文不回补脱敏占位符
- **提示词注入的边界**：模型没有代码执行能力，攻击面等于工具集的并集（读 / 删 / 发）。防线按有效性排序：能力最小化 > 数据流标记（`<mail>` 分隔）> 人工确认 > 提示词约束。任何新增「写文件 / 打开任意 URL / 执行命令」的能力都必须先设红线
- **上锁不是加密**：邮件在 `~/Library/Mail` 里仍是明文，锁只作用于 MailPilot 的 AI 通路

## 7. 构建与运行

```bash
make run      # 编译 + 组装 .app + 启动
make verify   # 只编译，快速检查错误
make test     # 断言测试（合成 .emlx，不需要磁盘权限）
make clean    # 删除构建产物
```

依赖：macOS 26+（Liquid Glass），Command Line Tools。

`make test` 跑 `scripts/test.sh`，三套共 74 条断言：上锁与访问控制（39）、索引与 FTS（18）、附件与线程（17）。全部用合成 `.emlx`，不依赖 XCTest 也不依赖完全磁盘访问权限，任何机器上都能跑。

没用 SwiftPM testTarget 的原因：可执行 target 不能被测试 target import，要先拆成 library。拆包会波及所有类型可见性，收益不抵风险，所以先用 `swiftc` 直接编译被测文件。

**版本号**写在 `Resources/Info.plist` 的 `CFBundleShortVersionString`，与 CHANGELOG 最新条目保持一致。
