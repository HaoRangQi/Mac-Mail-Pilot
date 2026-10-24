import Foundation

/// 演示数据：没有完全磁盘访问权限时，界面依然是一个"活的"邮件客户端。
/// 账号数量刻意做多，用来验证"按账号分组"的侧边栏在真实规模下的样子。
final class DemoStore: MailStore {
    let isDemo = true

    private var accountsList: [Account] = []
    private var boxes: [Mailbox] = []
    private var all: [Message] = []

    init() {
        buildAccounts()
        buildMailboxes()
        buildMessages()
        refreshCounts()
    }

    // MARK: - 构建

    private func buildAccounts() {
        let defs: [(String, String, String, String)] = [
            ("work", "公司邮箱", "me@company.com", "exchange"),
            ("icloud", "iCloud", "me@icloud.com", "icloud"),
            ("gmail", "Gmail", "me@gmail.com", "gmail"),
            ("outlook", "Outlook", "me@outlook.com", "exchange"),
            ("qq", "QQ 邮箱", "me@qq.com", "imap"),
        ]
        accountsList = defs.map { Account(id: "acc-\($0.0)", name: $0.1, email: $0.2, provider: $0.3) }
    }

    private func buildMailboxes() {
        let layout: [(String, String, Mailbox.Role)] = [
            ("inbox", "收件箱", .inbox),
            ("drafts", "草稿", .drafts),
            ("sent", "已发送", .sent),
            ("trash", "垃圾邮件", .trash),
        ]
        for account in accountsList {
            let key = account.id.replacingOccurrences(of: "acc-", with: "")
            for item in layout {
                boxes.append(Mailbox(
                    id: "mb-\(key)-\(item.0)",
                    accountID: account.id,
                    name: item.1,
                    role: item.2
                ))
            }
        }
    }

    private func buildMessages() {
        let now = Date()
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

        all = [
            // ---- 公司邮箱 ----
            Message(
                id: "msg-001", accountID: "acc-work", mailboxID: "mb-work-inbox",
                subject: "关于 Q4 批量采购的报价咨询",
                sender: "张伟", senderEmail: "zhangwei@acme-corp.com",
                date: ago(2), preview: "王总您好，我们计划在 Q4 进行一批设备批量采购，想请您帮忙核算一下阶梯报价……",
                body: """
                王总您好，

                我们计划在 Q4 进行一批设备批量采购（约 200 台），想请您帮忙核算一下阶梯报价：
                1. 100 台、200 台、500 台三个档位的单价分别是多少？
                2. 账期是否可以谈到 60 天？
                3. 交货周期大约多久？

                附件是我们的初步需求清单，麻烦您评估。期待本周五前收到回复，谢谢！

                张伟
                Acme Corp 采购部
                """,
                unread: true, needsReply: true, threadID: "th-acme-q4",
                attachments: [Attachment(filename: "Q4采购需求清单.xlsx", mime: "sheet", size: 48_213)]
            ),
            Message(
                id: "msg-003", accountID: "acc-work", mailboxID: "mb-work-inbox",
                subject: "Re: 服务器维护窗口确认",
                sender: "李娜", senderEmail: "lina@company.com",
                date: ago(8), preview: "收到，周六凌晨 2 点到 4 点的窗口没问题，我这边会提前把监控告警静音……",
                body: """
                收到，周六凌晨 2 点到 4 点的窗口没问题，我这边会提前把监控告警静音。

                另外确认一下：这次只做数据库主从切换，还是连同缓存层一起重启？如果缓存也要重启，建议把窗口延长到 5 点。

                李娜
                """,
                unread: true, needsReply: true, threadID: "th-maintenance"
            ),
            Message(
                id: "msg-004", accountID: "acc-work", mailboxID: "mb-work-inbox",
                subject: "2026 年度体检安排通知",
                sender: "行政部", senderEmail: "hr@company.com",
                date: ago(26), preview: "本年度体检定于 11 月 6 日至 10 日，请各位同事在系统中选择时段……",
                body: """
                各位同事：

                本年度体检定于 11 月 6 日至 10 日，地点为市第一体检中心。请在 HR 系统中选择时段，逾期将由系统自动分配。

                注意事项：
                1. 体检前一天 22:00 后禁食
                2. 携带身份证
                3. 如需改期请提前 2 个工作日告知

                行政部
                """,
                attachments: [Attachment(filename: "体检项目清单.pdf", mime: "pdf", size: 262_144)]
            ),
            Message(
                id: "msg-006", accountID: "acc-work", mailboxID: "mb-work-inbox",
                subject: "合同评审意见（第三轮）",
                sender: "王芳", senderEmail: "wangfang@acme-corp.com",
                date: ago(52), preview: "第三轮意见主要集中在付款节点和违约责任两处，其余条款我方无异议……",
                body: """
                第三轮意见主要集中在两处：

                一、付款节点
                建议改为「验收合格后 30 日内支付 70%，质保期满支付 30%」，原条款的 60 日对我方现金流压力较大。

                二、违约责任
                建议将违约金上限调整为合同总额的 10%，并对不可抗力情形作明确排除。

                其余条款我方无异议。请贵司法务确认后回签。

                王芳
                """,
                needsReply: true, threadID: "th-contract",
                attachments: [Attachment(filename: "合同_v3_批注.docx", mime: "docx", size: 96_512)]
            ),
            Message(
                id: "msg-009", accountID: "acc-work", mailboxID: "mb-work-inbox",
                subject: "招聘：高级后端工程师（内推）",
                sender: "陈磊", senderEmail: "chenlei@company.com",
                date: ago(120), preview: "团队在招一名高级后端，偏基础设施方向，方便的话帮我转一下……",
                body: """
                团队在招一名高级后端，偏基础设施方向，JD 如下：

                · 5 年以上后端经验，熟悉 Go 或 Rust
                · 有分布式存储或消息队列的实战经验
                · 能独立负责一个子系统的设计与落地

                方便的话帮我转一下，内推有奖。

                陈磊
                """,
                flagged: true
            ),
            Message(
                id: "msg-010", accountID: "acc-work", mailboxID: "mb-work-drafts",
                subject: "（草稿）Q4 报价方案",
                sender: "我", senderEmail: "me@company.com",
                date: ago(1), preview: "张伟您好，关于 200 台的阶梯报价，我们的方案是……",
                body: "张伟您好，\n\n关于 200 台的阶梯报价，我们的方案是：\n100 台：单价 ¥2,180\n200 台：单价 ¥2,050\n500 台：单价 ¥1,890\n\n账期可以给到 60 天。"
            ),
            Message(
                id: "msg-011", accountID: "acc-work", mailboxID: "mb-work-sent",
                subject: "Re: Q3 复盘会议纪要",
                sender: "我", senderEmail: "me@company.com",
                date: ago(70), preview: "纪要已更新到共享文档，补充了三个待办项和负责人……",
                body: "各位，纪要已更新到共享文档，补充了三个待办项和负责人，请相关同事本周内确认。",
                threadID: "th-q3"
            ),

            // ---- iCloud ----
            Message(
                id: "msg-002", accountID: "acc-icloud", mailboxID: "mb-icloud-inbox",
                subject: "Issue #612：值得关注的 5 个新库",
                sender: "Python Weekly", senderEmail: "news@pythonweekly.com",
                date: ago(5), preview: "本期精选：一个零依赖的 HTTP 框架、一个 FTS5 封装库，还有 3 个值得关注的工具……",
                body: """
                Python Weekly Issue #612

                本期精选：
                · 一个零依赖的 HTTP 框架，单文件 800 行
                · FTS5 封装库，让全文搜索变成三行代码
                · 终端里的 SQLite 浏览器
                · 一个把 SwiftUI 界面导出成图片的工具
                · 轻量级任务队列，无 Redis 依赖

                阅读全文：https://example.com/pw/612
                """,
                unread: true
            ),
            Message(
                id: "msg-005", accountID: "acc-icloud", mailboxID: "mb-icloud-inbox",
                subject: "你的 iCloud 存储空间即将用完",
                sender: "Apple", senderEmail: "no_reply@apple.com",
                date: ago(30), preview: "你的 iCloud 存储空间已使用 4.8 GB（共 5 GB）。升级方案可获取更多空间……",
                body: """
                你的 iCloud 存储空间已使用 4.8 GB（共 5 GB）。

                当空间用尽时，新的照片、文件和备份将无法上传。你可以删除不需要的内容，或升级到 iCloud+ 方案。

                管理存储空间：设置 → Apple 账户 → iCloud
                """,
                unread: true
            ),
            Message(
                id: "msg-008", accountID: "acc-icloud", mailboxID: "mb-icloud-inbox",
                subject: "本周阅读清单：关于注意力的三篇文章",
                sender: "得到每周荐书", senderEmail: "digest@example.com",
                date: ago(96), preview: "这期聊一个反直觉的结论：注意力不是被夺走的，是被我们自己交出去的……",
                body: """
                这期聊一个反直觉的结论：注意力不是被夺走的，是被我们自己交出去的。

                三篇文章分别从神经科学、产品设计和组织行为的角度讨论同一件事——为什么我们明知该专注，却仍然不断切换。

                约 25 分钟读完。
                """
            ),
            Message(
                id: "msg-012", accountID: "acc-icloud", mailboxID: "mb-icloud-sent",
                subject: "Re: 家庭照片共享",
                sender: "我", senderEmail: "me@icloud.com",
                date: ago(140), preview: "相册已经建好了，把你们都加进去了，链接在下面……",
                body: "相册已经建好了，把你们都加进去了。"
            ),

            // ---- Gmail ----
            Message(
                id: "msg-020", accountID: "acc-gmail", mailboxID: "mb-gmail-inbox",
                subject: "[mailpilot] #42 新的 Pull Request",
                sender: "GitHub", senderEmail: "notifications@github.com",
                date: ago(3), preview: "feat: 支持按账号分组显示侧边栏 — opened by you",
                body: "feat: 支持按账号分组显示侧边栏\n\nopened by you · 2 commits · 3 files changed\n\n查看：https://github.com/example/mailpilot/pull/42"
            ),
            Message(
                id: "msg-021", accountID: "acc-gmail", mailboxID: "mb-gmail-inbox",
                subject: "本周你错过的 12 个开源项目",
                sender: "GitHub Explore", senderEmail: "explore@github.com",
                date: ago(20), preview: "本周趋势：本地优先的笔记工具、SQLite 的向量扩展、还有一个 400 行的终端邮件客户端……",
                body: "本周趋势：\n· 本地优先的笔记工具\n· SQLite 的向量扩展\n· 一个 400 行的终端邮件客户端\n\n全部 12 个项目见网页版。",
                unread: true
            ),
            Message(
                id: "msg-022", accountID: "acc-gmail", mailboxID: "mb-gmail-inbox",
                subject: "Google 账号安全提醒",
                sender: "Google", senderEmail: "no-reply@accounts.google.com",
                date: ago(44), preview: "你的账号刚刚在一台新设备上登录，如果不是你本人操作，请立即检查……",
                body: "你的账号刚刚在一台新设备上登录。\n\n设备：MacBook Pro（macOS 27）\n位置：中国 上海\n\n如果不是你本人操作，请立即修改密码。",
                unread: true
            ),
            Message(
                id: "msg-023", accountID: "acc-gmail", mailboxID: "mb-gmail-sent",
                subject: "Re: 周末爬山",
                sender: "我", senderEmail: "me@gmail.com",
                date: ago(60), preview: "周六早上七点在山脚集合？我带水。",
                body: "周六早上七点在山脚集合？我带水。"
            ),

            // ---- Outlook ----
            Message(
                id: "msg-030", accountID: "acc-outlook", mailboxID: "mb-outlook-inbox",
                subject: "Microsoft 365 订阅即将续费",
                sender: "Microsoft", senderEmail: "account@microsoft.com",
                date: ago(7), preview: "你的 Microsoft 365 家庭版订阅将于 11 月 12 日续费，金额 ¥498……",
                body: "你的 Microsoft 365 家庭版订阅将于 11 月 12 日续费，金额 ¥498。\n\n如需更改付款方式或取消订阅，请访问账户页面。"
            ),
            Message(
                id: "msg-031", accountID: "acc-outlook", mailboxID: "mb-outlook-inbox",
                subject: "会议邀请：周一产品评审",
                sender: "王强", senderEmail: "wangqiang@company.com",
                date: ago(11), preview: "时间：周一 10:00-11:30，会议室 B，议题是下个版本的范围裁剪……",
                body: "时间：周一 10:00-11:30\n地点：会议室 B\n议题：下个版本的范围裁剪\n\n请提前看一下需求池里标红的条目。",
                needsReply: true
            ),
            Message(
                id: "msg-032", accountID: "acc-outlook", mailboxID: "mb-outlook-trash",
                subject: "【推广】限时优惠：云服务器 1 折起",
                sender: "云服务推广", senderEmail: "promo@example.net",
                date: ago(33), preview: "新用户专享，2 核 4G 首年 ¥99……",
                body: "新用户专享，2 核 4G 首年 ¥99。活动截止本月底。"
            ),

            // ---- QQ 邮箱 ----
            Message(
                id: "msg-040", accountID: "acc-qq", mailboxID: "mb-qq-inbox",
                subject: "腾讯云：11 月账单出账通知",
                sender: "腾讯云", senderEmail: "billing@tencent.com",
                date: ago(9), preview: "你的账户 11 月账单已出，应缴金额 ¥236.40，请在 7 日内完成支付……",
                body: "你的账户 11 月账单已出，应缴金额 ¥236.40。\n\n费用构成：\n· 云服务器 CVM：¥180.00\n· 对象存储 COS：¥42.40\n· 流量：¥14.00\n\n请在 7 日内完成支付。",
                unread: true
            ),
            Message(
                id: "msg-041", accountID: "acc-qq", mailboxID: "mb-qq-inbox",
                subject: "新设备登录提醒",
                sender: "QQ邮箱团队", senderEmail: "no-reply@qq.com",
                date: ago(72), preview: "你的邮箱刚刚在 Mac 客户端登录，如非本人操作请及时修改密码……",
                body: "你的邮箱刚刚在 Mac 客户端登录。\n\n如非本人操作，请及时修改密码并开启二次验证。"
            ),
            Message(
                id: "msg-042", accountID: "acc-qq", mailboxID: "mb-qq-sent",
                subject: "Re: 域名续费",
                sender: "我", senderEmail: "me@qq.com",
                date: ago(100), preview: "域名已经续了三年，发票稍后发你。",
                body: "域名已经续了三年，发票稍后发你。"
            ),
        ]
    }

    private func refreshCounts() {
        for index in boxes.indices {
            let id = boxes[index].id
            let rows = all.filter { $0.mailboxID == id }
            boxes[index].total = rows.count
            boxes[index].unread = rows.filter(\.unread).count
        }
    }

    // MARK: - MailStore

    func accounts() async throws -> [Account] { accountsList }

    func mailboxes() async throws -> [Mailbox] { boxes }

    func messages(mailboxID: String, limit: Int) async throws -> [Message] {
        rows(for: mailboxID).sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    func message(id: String) async throws -> Message? {
        all.first { $0.id == id }
    }

    func search(_ query: String, limit: Int) async throws -> [Message] {
        let q = query.lowercased()
        guard !q.isEmpty else { return [] }
        return all.filter {
            $0.subject.lowercased().contains(q)
                || $0.sender.lowercased().contains(q)
                || $0.senderEmail.lowercased().contains(q)
                || $0.body.lowercased().contains(q)
        }.sorted { $0.date > $1.date }.prefix(limit).map { $0 }
    }

    /// 演示模式：直接从内存移除（演示数据本就不落盘）
    func moveToTrash(_ message: Message) async throws {
        all.removeAll { $0.id == message.id }
        refreshCounts()
    }

    func badgeCounts() async throws -> [String: Int] {
        var out: [String: Int] = [:]
        for box in SmartBox.allCases {
            out[box.rawValue] = rows(for: box.rawValue).count
        }
        return out
    }

    // MARK: - 聚合

    private func rows(for id: String) -> [Message] {
        guard let smart = SmartBox(rawValue: id) else {
            return all.filter { $0.mailboxID == id }
        }
        switch smart {
        case .allInbox:
            let ids = Set(boxes.filter { $0.role == .inbox }.map(\.id))
            return all.filter { ids.contains($0.mailboxID) }
        case .allFlagged:
            return all.filter(\.flagged)
        case .allDrafts:
            let ids = Set(boxes.filter { $0.role == .drafts }.map(\.id))
            return all.filter { ids.contains($0.mailboxID) }
        case .allSent:
            let ids = Set(boxes.filter { $0.role == .sent }.map(\.id))
            return all.filter { ids.contains($0.mailboxID) }
        case .today:
            return all.filter { Calendar.current.isDateInToday($0.date) }
        }
    }
}
