import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var animated: Bool = false
    /// Retry closure — provided only for error messages (⚠️) so the user can re-send
    /// the failed query with a single tap instead of retyping.
    var onRetry: (() -> Void)?
    @State private var showCopied = false
    @State private var appeared = false

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
        .opacity(animated && !appeared ? 0 : 1)
        .offset(y: animated && !appeared ? 16 : 0)
        .onAppear {
            guard animated, !appeared else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                appeared = true
            }
        }
    }

    /// True if this is an error/failure message from the AI (network error, timeout, etc.)
    private var isErrorMessage: Bool {
        !message.isUser && message.content.hasPrefix("⚠️")
    }

    // MARK: - Markdown Rendering

    /// Renders text with Markdown support (bold, italic, etc.).
    /// Falls back to plain text if Markdown parsing fails.
    private func markdownText(_ content: String, foregroundColor: Color = .primary) -> Text {
        // AttributedString(markdown:) supports **bold**, *italic*, ~strikethrough~, `code`
        if let attributed = try? AttributedString(markdown: content,
                                                   options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(content)
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
                markdownText(message.content)
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
                    // Retry button for error messages — tap to re-send the failed query
                    if isErrorMessage, let onRetry {
                        Button {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            onRetry()
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 11, weight: .medium))
                                Text("重试")
                                    .font(.caption2)
                                    .fontWeight(.medium)
                            }
                            .foregroundColor(Color("AccentPrimary"))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                Capsule()
                                    .fill(Color("AccentPrimary").opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
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
