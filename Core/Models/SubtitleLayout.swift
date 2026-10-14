import Foundation
import CoreGraphics

/// Geometry shared by playback overlays and exported captions. Playback coordinates
/// have a top-left origin; exported Core Image placement uses the same bottom inset.
public enum SubtitleLayout {
    public static func videoFrame(size: CGSize, in viewport: CGRect) -> CGRect {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              viewport.width > 0, viewport.height > 0 else { return viewport }
        let scale = min(viewport.width / size.width, viewport.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: viewport.midX - fitted.width / 2, y: viewport.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    public static func bottomInset(for size: CGSize) -> CGFloat {
        max(8, size.height * (size.height > size.width ? 0.05 : 0.06))
    }

    public static func widthFraction(for size: CGSize) -> CGFloat { size.height > size.width ? 0.88 : 0.90 }

    public static func exportFontSize(for size: CGSize) -> CGFloat { max(14, min(72, min(size.width, size.height) * 0.045)) }

    public static func playbackFontSize(for size: CGSize) -> CGFloat { max(18, min(22, min(size.width, size.height) * 0.065)) }

    public static func playbackRegion(video: CGRect, safeBounds: CGRect, controlsHeight: CGFloat) -> CGRect {
        let visible = video.intersection(safeBounds)
        guard !visible.isNull, !visible.isEmpty else { return safeBounds.insetBy(dx: 12, dy: 12) }
        let width = max(1, min(visible.width * widthFraction(for: video.size), safeBounds.width - 24))
        let bottom = min(visible.maxY - bottomInset(for: video.size), safeBounds.maxY - max(0, controlsHeight) - 12)
        let top = max(visible.minY + 8, safeBounds.minY + 8)
        let height = max(1, min(video.height * 0.45, bottom - top))
        return CGRect(x: visible.midX - width / 2, y: max(top, bottom - height), width: width, height: height)
    }
}
