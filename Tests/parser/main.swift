import Foundation

var passed = 0
var failed = 0

func check(_ condition: Bool, _ name: String) {
    if condition { passed += 1; print("  ✅ \(name)") }
    else { failed += 1; print("  ❌ \(name)") }
}

let workDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("mailpilot-parser-test-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: workDir) }

let dir = workDir.appendingPathComponent("mail", isDirectory: true)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

let pngBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
let pdfBase64 = "JVBERi0xLjQKJeLjz9MKMSAwIG9iago8PC9UeXBlL0NhdGFsb2c+PgplbmRvYmoK"

let mime = """
Content-Type: multipart/mixed; boundary="BOUND1"
Subject: 带附件的邮件
From: Alice <alice@corp.com>
To: me@example.com
Date: Mon, 27 Oct 2026 10:00:00 +0800
Message-ID: <attach1@x>

--BOUND1
Content-Type: text/plain; charset=utf-8

这是正文。
--BOUND1
Content-Type: text/html; charset=utf-8

<html><body><img src="cid:logo"><p>HTML 正文</p></body></html>
--BOUND1
Content-Type: image/png
Content-ID: <logo>
Content-Transfer-Encoding: base64

\(pngBase64)
--BOUND1
Content-Type: application/pdf; name="report.pdf"
Content-Disposition: attachment; filename="report.pdf"
Content-Transfer-Encoding: base64

\(pdfBase64)
--BOUND1--
"""
let data = mime.data(using: .utf8)!
var file = Data("\(data.count)\n".utf8)
file.append(data)
let url = dir.appendingPathComponent("1.emlx")
try! file.write(to: url)

// MARK: - 解析

print("\n[1] 附件元数据")
let parsed = EmlxParser.parse(url: url, includeBody: true)
check(parsed != nil, "解析成功")
let attachments = parsed?.attachments ?? []
check(attachments.count == 1, "只把 PDF 当附件（内联图不算）")
check(attachments.first?.filename == "report.pdf", "文件名解析正确")
check(attachments.first?.mime == "application/pdf", "MIME 类型正确")
check((attachments.first?.size ?? 0) > 0, "大小估算大于 0")
check(parsed?.hasAttachments == true, "hasAttachments 为真")

print("\n[2] 正文与内联图")
check(parsed?.body.contains("这是正文") == true, "纯文本正文正常")
check(parsed?.htmlBody.contains("HTML 正文") == true, "HTML 正文保留")
check(parsed?.inlineImages["logo"] != nil, "cid 内联图被收集")
check(parsed?.attachments.contains { $0.mime.hasPrefix("image/") } == false, "内联图不出现在附件列表")

print("\n[3] 按 partIndex 取字节")
let pdfData = EmlxParser.attachmentData(url: url, partIndex: attachments.first!.partIndex)
check(pdfData != nil, "能取回附件字节")
check(pdfData == Data(base64Encoded: pdfBase64), "字节与原始内容一致")
check(pdfData?.prefix(4) == Data("%PDF".utf8), "取回的是 PDF 头")

print("\n[4] 列表模式不读大文件")
let listOnly = EmlxParser.parse(url: url, includeBody: false)
check(listOnly?.attachments.count == 1, "列表模式也能拿到附件元数据（列表要显示回形针）")

// MARK: - 5. 线程根

print("\n[5] 线程根")
do {
    let replyMime = """
    Subject: Re: 方案讨论
    From: Bob <bob@corp.com>
    Date: Tue, 28 Oct 2026 09:00:00 +0800
    Message-ID: <reply@x>
    In-Reply-To: <root@x>
    References: <root@x> <mid@x>

    收到，我来跟进。
    """
    let replyData = replyMime.data(using: .utf8)!
    var replyFile = Data("\(replyData.count)\n".utf8)
    replyFile.append(replyData)
    let replyURL = dir.appendingPathComponent("2.emlx")
    try! replyFile.write(to: replyURL)

    let reply = EmlxParser.parse(url: replyURL, includeBody: true)
    check(reply?.references == ["root@x", "mid@x"], "References 解析成不带尖括号的两项")
    check(reply?.threadRoot == "root@x", "线程根取 References 的第一个（最旧）")

    let orphanMime = """
    Subject: 独立邮件
    From: Carol <carol@corp.com>
    Date: Wed, 29 Oct 2026 09:00:00 +0800
    Message-ID: <solo@x>

    没有回复链。
    """
    let orphanData = orphanMime.data(using: .utf8)!
    var orphanFile = Data("\(orphanData.count)\n".utf8)
    orphanFile.append(orphanData)
    let orphanURL = dir.appendingPathComponent("3.emlx")
    try! orphanFile.write(to: orphanURL)

    let solo = EmlxParser.parse(url: orphanURL, includeBody: true)
    check(solo?.threadRoot == "solo@x", "没有回复链时线程根是自己的 Message-ID")
}

print("\n========================================")
print("通过 \(passed) · 失败 \(failed)")
exit(failed == 0 ? 0 : 1)
