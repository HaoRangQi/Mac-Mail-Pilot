import AppKit
import CoreImage
import Foundation

/// 背景图的加载、模糊与缓存。
///
/// 两个要点：
/// 1. **模糊只算一次**。`Image.blur()` 会在每次视图重绘时重新做一遍高斯模糊，
///    铺满窗口的大图每帧算一次直接卡死；这里用 CoreImage 预先烘好一张位图缓存起来。
/// 2. **图片要落到本机支持目录**。用户选的桌面图可能被移动或删除，远程图每次启动重下也不现实。
///    选中/下载时立刻拷一份到 `~/Library/Application Support/MailPilot/background.<ext>`。
enum BackgroundImage {
    /// 原图缓存（路径 → 图）
    private static var rawCache: [String: NSImage] = [:]
    /// 模糊图缓存（"路径|半径" → 图）
    private static var blurredCache: [String: NSImage] = [:]
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - 取图

    static func raw(path: String) -> NSImage? {
        if let cached = rawCache[path] { return cached }
        guard let source = NSImage(contentsOfFile: path) else { return nil }
        // 大图先缩到 2560 以内：铺满窗口根本看不出差别，
        // 但模糊半径是按像素算的，原尺寸 4K 图每调一格滑杆要卡半秒
        let image = downscaled(source, maxSide: 2560)
        rawCache[path] = image
        return image
    }

    private static func downscaled(_ image: NSImage, maxSide: CGFloat) -> NSImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxSide else { return image }
        let ratio = maxSide / longest
        let target = NSSize(width: size.width * ratio, height: size.height * ratio)

        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let ci = CIImage(cgImage: cg)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: ratio, y: ratio))
        guard let output = ciContext.createCGImage(scaled, from: scaled.extent) else { return image }
        return NSImage(cgImage: output, size: target)
    }

    /// 按当前设置取一张已经模糊好的图
    static func rendered(path: String, blur: Double) -> NSImage? {
        let radius = max(blur, 0)
        let key = "\(path)|\(Int(radius.rounded()))"
        if let cached = blurredCache[key] { return cached }
        guard let source = raw(path: path) else { return nil }

        let image: NSImage
        if radius < 0.5 {
            image = source
        } else {
            image = gaussian(source, radius: radius) ?? source
        }

        // 只留最近 8 张，拖动滑杆时不至于越攒越多
        if blurredCache.count >= 8 { blurredCache.removeAll() }
        blurredCache[key] = image
        return image
    }

    private static func gaussian(_ image: NSImage, radius: Double) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let input = CIImage(cgImage: cg)
        // 先向外扩一圈再模糊，否则四边会出现透明软边
        let clamped = input.clampedToExtent()
        let blurred = clamped.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        guard let output = ciContext.createCGImage(blurred, from: input.extent) else { return nil }
        return NSImage(cgImage: output, size: image.size)
    }

    // MARK: - 落地

    /// 缓存目录里的固定文件名，换图直接覆盖
    static var cacheURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MailPilot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("background.img")
    }

    /// 把用户选的文件拷进缓存目录，返回缓存路径
    static func adopt(local url: URL) throws -> String {
        guard let target = cacheURL else { throw BackgroundError.noCacheDirectory }
        let data = try Data(contentsOf: url)
        guard NSImage(data: data) != nil else { throw BackgroundError.notAnImage }
        clearCache()
        try data.write(to: target, options: .atomic)
        return target.path
    }

    /// 下载远程图片并落地，返回缓存路径
    static func adopt(remote urlString: String) async throws -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            throw BackgroundError.badURL
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw BackgroundError.downloadFailed(http.statusCode)
        }
        guard NSImage(data: data) != nil else { throw BackgroundError.notAnImage }
        guard let target = cacheURL else { throw BackgroundError.noCacheDirectory }
        clearCache()
        try data.write(to: target, options: .atomic)
        return target.path
    }

    static func clearCache() {
        rawCache.removeAll()
        blurredCache.removeAll()
    }

    static func removeFile() {
        clearCache()
        if let url = cacheURL { try? FileManager.default.removeItem(at: url) }
    }
}

enum BackgroundError: LocalizedError {
    case noCacheDirectory
    case notAnImage
    case badURL
    case downloadFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noCacheDirectory: return "无法创建缓存目录"
        case .notAnImage: return "这个文件不是可识别的图片"
        case .badURL: return "链接格式不对，需要 http 或 https 开头"
        case .downloadFailed(let code): return "下载失败（HTTP \(code)）"
        }
    }
}
