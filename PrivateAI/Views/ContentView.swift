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
    @State private var locationOn = true
    @State private var healthOn = true
    @State private var notifOn = true
    @State private var calendarOn = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color("AccentPrimary").opacity(0.9), Color("AccentSecondary")],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if step == 0 {
                welcomeStep
            } else {
                permissionStep
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
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
                Text("iosclaw")
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
                withAnimation { step = 1 }
            } label: {
                Text("下一步")
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

    // MARK: - Step 1: Permissions

    private var permissionStep: some View {
        VStack(spacing: 24) {
            Spacer()

            Text("选择要开启的功能")
                .font(.title2.bold())
                .foregroundColor(.white)

            Text("这些权限帮助我更好地了解你\n所有数据只存在本机")
                .multilineTextAlignment(.center)
                .foregroundColor(.white.opacity(0.8))

            VStack(spacing: 12) {
                PermissionToggleRow(icon: "location.fill", color: .blue,
                    title: "位置记录", isOn: $locationOn)
                PermissionToggleRow(icon: "heart.fill", color: .red,
                    title: "健康数据（步数/睡眠）", isOn: $healthOn)
                PermissionToggleRow(icon: "bell.fill", color: .yellow,
                    title: "每日提醒", isOn: $notifOn)
                PermissionToggleRow(icon: "calendar", color: .green,
                    title: "日历行程", isOn: $calendarOn)
            }
            .padding(.horizontal, 24)

            Spacer()

            Button {
                applyPermissions()
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

    // MARK: - Apply Permissions

    private func applyPermissions() {
        if locationOn { appState.requestLocationPermission() }
        if healthOn { appState.requestHealthPermission() }
        if calendarOn { appState.toggleCalendar(true) }
        // notifications handled separately since need context
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

private struct PermissionToggleRow: View {
    let icon: String
    let color: Color
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(color)
                    .frame(width: 36, height: 36)
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.white)
            }

            Text(title)
                .font(.body)
                .foregroundColor(.white)

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .tint(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.white.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
