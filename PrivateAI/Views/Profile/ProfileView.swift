import SwiftUI

struct ProfileView: View {
    @ObservedObject var viewModel: ProfileViewModel

    @State private var newInterest: String = ""
    @FocusState private var interestFieldFocused: Bool

    private var todaySteps: Int {
        UserDefaults(suiteName: "group.com.privateai.assistant")?.integer(forKey: "widget_today_steps") ?? 0
    }
    private var todaySleep: Double {
        UserDefaults(suiteName: "group.com.privateai.assistant")?.double(forKey: "widget_today_sleep_hours") ?? 0
    }
    private var todayMood: String {
        UserDefaults(suiteName: "group.com.privateai.assistant")?.string(forKey: "widget_today_mood") ?? ""
    }

    var body: some View {
        NavigationStack {
            Form {
                // Today's snapshot
                if todaySteps > 0 || todaySleep > 0 || !todayMood.isEmpty {
                    Section("今日快照") {
                        HStack(spacing: 0) {
                            ProfileStatCell(icon: "figure.walk", value: "\(todaySteps.formatted())", label: "步数", color: .blue)
                            Divider()
                            ProfileStatCell(icon: "moon.fill", value: String(format: "%.1f", todaySleep), label: "睡眠h", color: .indigo)
                            Divider()
                            ProfileStatCell(icon: "face.smiling", value: todayMood.isEmpty ? "—" : todayMood, label: "心情", color: .pink)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                // Basic Info
                Section("基本信息") {
                    LabeledTextField(label: "姓名", text: $viewModel.profile.name, placeholder: "你叫什么名字？")

                    DatePicker(
                        "生日",
                        selection: Binding(
                            get: { viewModel.profile.birthday ?? Date() },
                            set: { viewModel.profile.birthday = $0 }
                        ),
                        displayedComponents: .date
                    )

                    LabeledTextField(label: "职业", text: $viewModel.profile.occupation, placeholder: "你的职业是？")
                }

                // Interests
                Section("兴趣爱好") {
                    ForEach(viewModel.profile.interests, id: \.self) { interest in
                        HStack {
                            Text(interest)
                            Spacer()
                            Button {
                                viewModel.removeInterest(interest)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack {
                        TextField("添加兴趣...", text: $newInterest)
                            .focused($interestFieldFocused)
                            .onSubmit {
                                viewModel.addInterest(newInterest)
                                newInterest = ""
                            }
                        if !newInterest.isEmpty {
                            Button {
                                viewModel.addInterest(newInterest)
                                newInterest = ""
                                interestFieldFocused = false
                            } label: {
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(Color("AccentPrimary"))
                            }
                        }
                    }
                }

                // Family
                Section {
                    ForEach(viewModel.profile.familyMembers) { member in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name).font(.headline)
                                Text(member.relation).font(.caption).foregroundColor(.secondary)
                                if !member.notes.isEmpty {
                                    Text(member.notes).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Button {
                                viewModel.removeFamilyMember(member)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    Button {
                        viewModel.showAddFamily = true
                    } label: {
                        Label("添加家人", systemImage: "person.badge.plus")
                    }
                } header: {
                    Text("家人信息")
                }

                // Notes
                Section("备注") {
                    TextEditor(text: $viewModel.profile.notes)
                        .frame(minHeight: 80)
                }

                // AI Style
                Section("AI 风格") {
                    Picker("风格", selection: $viewModel.profile.aiStyle) {
                        ForEach(UserProfileData.AIStyle.allCases, id: \.self) { style in
                            Text(style.label).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("我的资料")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") { viewModel.save() }
                        .fontWeight(.semibold)
                        .foregroundColor(Color("AccentPrimary"))
                }
            }
            .overlay {
                if viewModel.isSaved {
                    SavedToast()
                }
            }
            .sheet(isPresented: $viewModel.showAddFamily) {
                AddFamilySheet(viewModel: viewModel)
            }
        }
    }
}

// MARK: - Add Family Sheet

struct AddFamilySheet: View {
    @ObservedObject var viewModel: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LabeledTextField(label: "姓名", text: $viewModel.newFamilyName, placeholder: "家人的名字")
                LabeledTextField(label: "关系", text: $viewModel.newFamilyRelation, placeholder: "如：老婆、爸爸、妈妈")
                LabeledTextField(label: "备注", text: $viewModel.newFamilyNotes, placeholder: "喜好、过敏等信息")
            }
            .navigationTitle("添加家人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        viewModel.addFamilyMember()
                        dismiss()
                    }
                    .disabled(viewModel.newFamilyName.isEmpty || viewModel.newFamilyRelation.isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Helpers

struct ProfileStatCell: View {
    let icon: String
    let value: String
    let label: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).foregroundColor(color).font(.title3)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded))
            Text(label).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

struct LabeledTextField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundColor(.primary)
                .frame(width: 50, alignment: .leading)
            TextField(placeholder, text: $text)
                .foregroundColor(.secondary)
        }
    }
}

struct SavedToast: View {
    var body: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text("已保存")
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.regularMaterial)
            .clipShape(Capsule())
            .shadow(radius: 8)
            .padding(.bottom, 100)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
