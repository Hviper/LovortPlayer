import CoreImage
import CoreText
import Foundation

/// Immutable timeline and a bounded, thread-safe cache; no layer per subtitle and no full-video bitmap allocation.
final class SubtitleBurnInRenderer: @unchecked Sendable {
    private let cues: [SubtitleExportCue]
    private let cache = NSCache<NSString, CIImage>()

    init(cues: [SubtitleExportCue]) {
        self.cues = cues
        cache.countLimit = 8
        cache.totalCostLimit = 24 * 1_024 * 1_024
    }

    func image(at time: TimeInterval, over source: CIImage) throws -> CIImage {
        guard time.isFinite else { return source }
        let milliseconds = time * 1000
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if Double(cues[mid].startMilliseconds) <= milliseconds { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return source }
        let cue = cues[low - 1]
        guard milliseconds < Double(cue.endMilliseconds), !cue.text.isEmpty else { return source }
        let extent = source.extent
        guard extent.width.isFinite, extent.height.isFinite, extent.width > 0, extent.height > 0 else {
            throw SubtitleVideoExportError.failed("视频画面尺寸无效")
        }
        let width = max(1, Int(extent.width * SubtitleLayout.widthFraction(for: extent.size)))
        let key = "\(width)x\(Int(extent.height)):\(cue.text)" as NSString
        let caption: CIImage
        if let stored = cache.object(forKey: key) { caption = stored } else {
            caption = try render(cue.text, width: width, videoSize: extent.size)
            cache.setObject(caption, forKey: key, cost: Int(caption.extent.width * caption.extent.height * 4))
        }
        let placed = caption.transformed(by: CGAffineTransform(
            translationX: extent.midX - caption.extent.width / 2,
            y: extent.minY + SubtitleLayout.bottomInset(for: extent.size)))
        return placed.composited(over: source).cropped(to: extent)
    }

    private func render(_ text: String, width: Int, videoSize: CGSize) throws -> CIImage {
        let videoHeight = videoSize.height
        let padding: CGFloat = max(8, videoHeight * 0.012)
        var fontSize = SubtitleLayout.exportFontSize(for: videoSize)
        var alignment = CTTextAlignment.center
        let paragraph = withUnsafePointer(to: &alignment) { pointer in
            var setting = CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: pointer)
            return CTParagraphStyleCreate(&setting, 1)
        }
        var setter: CTFramesetter!
        var measured = CGSize.zero
        while true {
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
                NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
            ]
            setter = CTFramesetterCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
            measured = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(), nil,
                CGSize(width: CGFloat(width) - padding * 2, height: .greatestFiniteMagnitude), nil)
            if measured.height + padding * 2 <= videoHeight * 0.42 { break }
            guard fontSize > 12 else { throw SubtitleVideoExportError.failed("字幕行数过多，无法完整放入画面，请先拆分字幕") }
            fontSize = max(12, fontSize - 2)
        }
        let height = max(1, Int(ceil(measured.height + padding * 2 + 2)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw SubtitleVideoExportError.failed("字幕画面缓冲区创建失败")
        }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(gray: 0, alpha: 0.7))
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: padding / 2, cornerHeight: padding / 2, transform: nil))
        context.fillPath()
        let path = CGPath(rect: bounds.insetBy(dx: padding, dy: padding), transform: nil)
        let frame = CTFramesetterCreateFrame(setter, CFRange(), path, nil)
        guard CTFrameGetVisibleStringRange(frame).length == (text as NSString).length else {
            throw SubtitleVideoExportError.failed("字幕无法完整渲染，请先拆分字幕")
        }
        CTFrameDraw(frame, context)
        guard let image = context.makeImage() else { throw SubtitleVideoExportError.failed("字幕画面生成失败") }
        return CIImage(cgImage: image)
    }
}
