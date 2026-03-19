import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    @State private var showCopied = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if message.isUser {
                Spacer(minLength: 60)
                userBubble
            } else {
                aiBubble
                Spacer(minLength: 60)
            }
        }
    }

    // MARK: - User Bubble

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(message.content)
                .font(.body)
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color("AccentPrimary"))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .contextMenu {
                    bubbleContextMenu
                }

            HStack(spacing: 4) {
                if showCopied {
                    copiedIndicator
                }
                Text(message.timestamp.timeDisplay)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - AI Bubble

    private var aiBubble: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // Avatar
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color("AccentPrimary"), Color("AccentSecondary")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundColor(.white)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.content)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .contextMenu {
                        bubbleContextMenu
                    }

                HStack(spacing: 4) {
                    Text(message.timestamp.timeDisplay)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if showCopied {
                        copiedIndicator
                    }
                }
            }
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var bubbleContextMenu: some View {
        Button {
            UIPasteboard.general.string = message.content
            withAnimation(.easeInOut(duration: 0.2)) {
                showCopied = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                withAnimation(.easeOut(duration: 0.3)) {
                    showCopied = false
                }
            }
        } label: {
            Label("复制文字", systemImage: "doc.on.doc")
        }

        Button {
            let text = message.content
            let activityVC = UIActivityViewController(
                activityItems: [text],
                applicationActivities: nil
            )
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                // Find the topmost presented controller
                var topVC = rootVC
                while let presented = topVC.presentedViewController {
                    topVC = presented
                }
                activityVC.popoverPresentationController?.sourceView = topVC.view
                topVC.present(activityVC, animated: true)
            }
        } label: {
            Label("分享", systemImage: "square.and.arrow.up")
        }

        if !message.isUser {
            Button {
                // Select all text for easy copying
                UIPasteboard.general.string = message.content
                withAnimation(.easeInOut(duration: 0.2)) {
                    showCopied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeOut(duration: 0.3)) {
                        showCopied = false
                    }
                }
            } label: {
                Label("复制全部回复", systemImage: "text.quote")
            }
        }
    }

    // MARK: - Copied Indicator

    private var copiedIndicator: some View {
        HStack(spacing: 2) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
            Text("已复制")
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(Color("AccentPrimary"))
        .transition(.opacity.combined(with: .scale(scale: 0.8)))
    }
}

// MARK: - Date extension

private extension Date {
    var timeDisplay: String {
        let fmt = DateFormatter()
        fmt.dateFormat = Calendar.current.isDateInToday(self) ? "HH:mm" : "M/d HH:mm"
        return fmt.string(from: self)
    }
}
