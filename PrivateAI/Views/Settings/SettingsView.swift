import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: SettingsViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.managedObjectContext) private var context

    var body: some View {
        NavigationStack {
            Form {
                // Privacy & Permissions
                Section {
                    PermissionRow(
                        icon: "location.fill",
                        iconColor: .blue,
                        title: "位置记录",
                        subtitle: "记录你去过的地方",
                        isOn: Binding(
                            get: { appState.locationEnabled },
                            set: { appState.toggleLocation($0) }
                        )
                    )

                    PermissionRow(
                        icon: "heart.fill",
                        iconColor: .red,
                        title: "健康数据",
                        subtitle: "读取步数、运动、睡眠",
                        isOn: Binding(
                            get: { appState.healthEnabled },
                            set: { appState.toggleHealth($0) }
                        )
                    )

                    PermissionRow(
                        icon: "mic.fill",
                        iconColor: .orange,
                        title: "语音输入",
                        subtitle: "语音转文字（本地识别）",
                        isOn: Binding(
                            get: { appState.speechEnabled },
                            set: { appState.speechEnabled = $0 }
                        )
                    )

                    PermissionRow(
                        icon: "calendar",
                        iconColor: .green,
                        title: "日历权限",
                        subtitle: "读取你的日程和行程安排",
                        isOn: Binding(
                            get: { appState.calendarEnabled },
                            set: { appState.toggleCalendar($0) }
                        )
                    )

                    PermissionRow(
                        icon: "photo.fill",
                        iconColor: .purple,
                        title: "相册权限",
                        subtitle: "读取照片时间和位置元数据（不读图片内容）",
                        isOn: Binding(
                            get: { appState.photoEnabled },
                            set: { appState.togglePhoto($0) }
                        )
                    )
                } header: {
                    Label("权限管理", systemImage: "lock.shield")
                } footer: {
                    Text("所有数据只存在本机，不会上传到任何服务器。")
                }

                // Notification Settings
                Section {
                    PermissionRow(
                        icon: "bell.fill",
                        iconColor: .yellow,
                        title: "本地通知",
                        subtitle: "每日提醒 + 每周生活总结",
                        isOn: Binding(
                            get: { appState.notificationEnabled },
                            set: { appState.toggleNotifications($0, context: context) }
                        )
                    )

                    if appState.notificationEnabled {
                        HStack {
                            Text("每日提醒时间")
                            Spacer()
                            DatePicker(
                                "",
                                selection: Binding(
                                    get: {
                                        Calendar.current.date(
                                            bySettingHour: appState.notifHour,
                                            minute: appState.notifMinute,
                                            second: 0,
                                            of: Date()
                                        ) ?? Date()
                                    },
                                    set: { date in
                                        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
                                        appState.notifHour = comps.hour ?? 21
                                        appState.notifMinute = comps.minute ?? 0
                                        appState.notificationService.scheduleDailyReminder(
                                            hour: appState.notifHour,
                                            minute: appState.notifMinute
                                        )
                                    }
                                ),
                                displayedComponents: .hourAndMinute
                            )
                            .labelsHidden()
                        }
                    }
                } header: {
                    Label("通知设置", systemImage: "bell")
                } footer: {
                    Text("每周日早上 9 点自动发送本周生活回顾。")
                }

                // Memory Settings
                Section {
                    Picker("保留记忆", selection: $appState.memoryRetentionDays) {
                        Text("30 天").tag(30)
                        Text("90 天").tag(90)
                        Text("180 天").tag(180)
                        Text("永久").tag(0)
                    }
                } header: {
                    Label("记忆设置", systemImage: "brain")
                }

                // Data Management
                Section {
                    Button {
                        viewModel.exportData()
                    } label: {
                        Label("导出数据", systemImage: "square.and.arrow.up")
                            .foregroundColor(Color("AccentPrimary"))
                    }

                    Button(role: .destructive) {
                        viewModel.showClearConfirm = true
                    } label: {
                        Label("清除所有数据", systemImage: "trash")
                    }
                } header: {
                    Label("数据管理", systemImage: "internaldrive")
                } footer: {
                    Text("导出数据将生成一个 JSON 文件，包含你的所有记录。")
                }

                // About
                Section("关于") {
                    InfoRow(title: "版本", value: "1.0.0")
                    InfoRow(title: "数据存储", value: "本机")
                    InfoRow(title: "网络权限", value: "无")
                    InfoRow(title: "隐私", value: "100% 本地")
                }
            }
            .navigationTitle("设置")
            .confirmationDialog(
                "确定清除所有数据？",
                isPresented: $viewModel.showClearConfirm,
                titleVisibility: .visible
            ) {
                Button("清除所有数据", role: .destructive) {
                    viewModel.clearAllData()
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此操作不可撤销，所有记录将被永久删除。")
            }
            .sheet(isPresented: $viewModel.showExportAlert) {
                if let url = viewModel.exportURL {
                    ShareSheet(items: [url])
                }
            }
        }
    }
}

// MARK: - Permission Row

struct PermissionRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor)
                    .frame(width: 32, height: 32)
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body)
                Text(subtitle).font(.caption).foregroundColor(.secondary)
            }

            Spacer()
            Toggle("", isOn: $isOn).labelsHidden()
        }
    }
}

// MARK: - Info Row

struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}

// MARK: - Share Sheet

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
