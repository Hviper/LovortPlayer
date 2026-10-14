#if canImport(LovortPlayerCore)
import LovortPlayerCore
#endif
import SwiftUI

public struct AISubtitleOverlayView: View {
    @ObservedObject private var display = SubtitleDisplayPreferences.shared
    public let subtitle: SubtitleLine?
    public let videoSize: CGSize
    public let controlsHeight: CGFloat

    public init(subtitle: SubtitleLine?, videoSize: CGSize = .zero, controlsHeight: CGFloat = 0) {
        self.subtitle = subtitle
        self.videoSize = videoSize
        self.controlsHeight = controlsHeight
    }

    public var body: some View {
        GeometryReader { geometry in
            let safeBounds = CGRect(origin: .zero, size: geometry.size)
            let insets = geometry.safeAreaInsets
            let viewport = CGRect(x: -insets.leading, y: -insets.top,
                                  width: geometry.size.width + insets.leading + insets.trailing,
                                  height: geometry.size.height + insets.top + insets.bottom)
            let video = SubtitleLayout.videoFrame(size: videoSize, in: viewport)
            let region = placement(video: video, safeBounds: safeBounds)
            let fontSize = SubtitleLayout.playbackFontSize(for: video.size) * CGFloat(display.scale)
            if let sub = subtitle {
                ViewThatFits(in: .vertical) {
                    caption(sub, fontSize: fontSize)
                        .fixedSize(horizontal: false, vertical: true)
                        .allowsHitTesting(false)
                    // Keep long bilingual captions readable without painting outside the
                    // video/safe area. Scrolling is enabled only for this overflow case.
                    ScrollView(.vertical) {
                        caption(sub, fontSize: fontSize)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(height: region.height)
                    .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHint("字幕较长，可上下滑动查看")
                    .id(sub.id)
                }
                .frame(width: region.width, height: region.height, alignment: .bottom)
                .clipped()
                .position(x: region.midX, y: region.midY)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsHeight)
    }
    private func placement(video: CGRect, safeBounds: CGRect) -> CGRect {
        var region = SubtitleLayout.playbackRegion(video: video, safeBounds: safeBounds, controlsHeight: controlsHeight)
        let lower = max(video.minY, safeBounds.minY) + 4
        let upper = min(video.maxY - 4, safeBounds.maxY - controlsHeight - 12) - region.height
        region.origin.y = max(lower, min(upper, region.origin.y - CGFloat(display.verticalOffset) * video.height))
        return region
    }
    private func caption(_ sub: SubtitleLine, fontSize: CGFloat) -> some View {
        VStack(spacing: 4) {
            if display.textMode != .original, let trans = sub.translatedText, !trans.isEmpty {
                Text(trans)
                    .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            if !sub.originalText.isEmpty, (display.textMode == .original || (display.textMode == .bilingual && sub.originalText != sub.translatedText) || (sub.translatedText?.isEmpty ?? true)) {
                Text(sub.originalText)
                    .font(.system(size: (display.textMode == .original || (sub.translatedText?.isEmpty ?? true)) ? fontSize : fontSize * 0.76, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
            }
        }
        .multilineTextAlignment(.center)
        .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
    }

}
