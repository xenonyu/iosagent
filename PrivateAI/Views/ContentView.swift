import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        if appState.onboardingDone {
            MainTabView()
        } else {
            OnboardingView()
        }
    }
}

// MARK: - Onboarding

struct OnboardingView: View {
    @EnvironmentObject var appState: AppState
    @State private var step = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color("AccentPrimary").opacity(0.9), Color("AccentSecondary")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                // Icon
                ZStack {
                    Circle()
                        .fill(.white.opacity(0.15))
                        .frame(width: 120, height: 120)
                    Image(systemName: "brain.head.profile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 60)
                        .foregroundColor(.white)
                }

                VStack(spacing: 12) {
                    Text("私人 AI 助理")
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(.white)

                    Text("你的专属记忆助手\n所有数据仅存本地，绝对私密")
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .foregroundColor(.white.opacity(0.9))
                }

                // Feature list
                VStack(alignment: .leading, spacing: 16) {
                    FeatureRow(icon: "lock.shield.fill",
                               title: "完全本地",
                               subtitle: "不联网，不上云，数据永远在你手机里")
                    FeatureRow(icon: "brain",
                               title: "智能问答",
                               subtitle: "问我你做了什么、去了哪里、心情如何")
                    FeatureRow(icon: "chart.line.uptrend.xyaxis",
                               title: "生活记录",
                               subtitle: "自动采集位置、健康、日历等数据")
                }
                .padding(.horizontal, 24)

                Spacer()

                Button {
                    appState.onboardingDone = true
                } label: {
                    Text("开始使用")
                        .font(.headline)
                        .foregroundColor(Color("AccentPrimary"))
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.white)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                    .foregroundColor(.white)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }
}
