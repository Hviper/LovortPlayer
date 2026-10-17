import SwiftUI
import AppKit

public struct CopyableFieldView: View {
    public let title: String
    public let value: String
    public let displayValue: String?
    public let isSecret: Bool
    public let hint: String?
    public let icon: String

    @State private var isRevealed: Bool = false
    @State private var hasCopied: Bool = false

    public init(
        title: String,
        value: String,
        displayValue: String? = nil,
        isSecret: Bool = false,
        hint: String? = nil,
        icon: String = "doc.on.doc"
    ) {
        self.title = title
        self.value = value
        self.displayValue = displayValue
        self.isSecret = isSecret
        self.hint = hint
        self.icon = icon
    }

    private var activeDisplayText: String {
        if isSecret && !isRevealed {
            return SecretRedactor.maskSecret(value)
        }
        return displayValue ?? value
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                if let hint = hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            HStack(spacing: 8) {
                Text(activeDisplayText.isEmpty ? "—" : activeDisplayText)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSecret && !value.isEmpty {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(isRevealed ? "隐藏口令" : "显示口令")
                }

                Button {
                    copyToClipboard()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: hasCopied ? "checkmark" : "doc.on.doc")
                        Text(hasCopied ? "已复制" : "复制")
                    }
                    .font(.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(value.isEmpty)
            }
            .padding(10)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
    }

    private func copyToClipboard() {
        guard !value.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation {
            hasCopied = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run {
                withAnimation {
                    hasCopied = false
                }
            }
        }
    }
}
