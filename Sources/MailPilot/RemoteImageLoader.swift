import Foundation

/// 远程图片代理下载器。
///
/// 存在意义：**WebView 永远零外联**。即使策略是「总是加载」，也不放开 CSP，
/// 而是由 App 用 URLSession 把图取回来、转成 data URI 后再进 WebView。
/// 这样做的附带好处：请求不带浏览器上下文（cookie/referrer）、可限大小、
/// 可限类型、可计数，失败只影响那一张图。
///
/// 约束（对应威胁模型 T2/T3/T7）：
/// - 只允许 http/https
/// - 单张 ≤2MB，一次合计 ≤8MB，最多 30 张
/// - 10s 超时，ephemeral session（不落盘缓存、不带 cookie）
/// - Content-Type 声明必须是 image/*，且魔法字节复核（服务端声明会撒谎）
/// - 失败的 URL 直接缺席——占位保持原样，不阻塞其他图
enum RemoteImageLoader {
    static let maxBytesPerImage = 2_097_152
    static let maxTotalBytes = 8_388_608
    static let maxImages = HTMLSanitizer.maxRemoteImages
    static let timeout: TimeInterval = 10

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    /// 返回 [原始 URL: 图片数据]。串行下载——一次最多 30 张，慢一点但行为可预期，
    /// 也不会同时朝几十个跟踪域名发包
    static func load(_ urls: [String]) async -> [String: Data] {
        var out: [String: Data] = [:]
        var total = 0

        for raw in urls.prefix(maxImages) {
            guard total < maxTotalBytes else { break }
            guard let url = URL(string: raw),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else { continue }

            guard let (data, response) = try? await session.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else { continue }

            // 服务端声明 + 魔法字节双重校验
            let declared = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard declared.hasPrefix("image/") else { continue }
            guard data.count <= maxBytesPerImage else { continue }
            guard HTMLSanitizer.imageMIMEType(data) != nil else { continue }

            out[raw] = data
            total += data.count
        }
        return out
    }
}
