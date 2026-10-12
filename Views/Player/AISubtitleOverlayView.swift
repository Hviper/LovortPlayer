import SwiftUI

public struct AISubtitleOverlayView: View {
    public let subtitle: SubtitleLine?

    public init(subtitle: SubtitleLine?) {
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack {
            Spacer()
            if let sub = subtitle {
                VStack(spacing: 4) {
                    if let trans = sub.translatedText, !trans.isEmpty {
                        Text(trans)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundColor(.white)
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.8), radius: 3, x: 0, y: 1)
                    }
                    
                    if !sub.originalText.isEmpty {
                        Text(sub.originalText)
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.8))
                            .multilineTextAlignment(.center)
                            .shadow(color: .black.opacity(0.8), radius: 2, x: 0, y: 1)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(.ultraThinMaterial)
                        .environment(\.colorScheme, .dark)
                        .opacity(0.65)
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 72)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: subtitle?.id)
    }
}
