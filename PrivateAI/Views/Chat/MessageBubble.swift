import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage

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

            Text(message.timestamp.timeDisplay)
                .font(.caption2)
                .foregroundColor(.secondary)
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

                Text(message.timestamp.timeDisplay)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
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
