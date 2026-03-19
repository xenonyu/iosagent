import SwiftUI
import CoreData

/// 悬浮快速记录按钮 + 弹出式记录面板
/// 在 MainTabView 上叠加，任意页面均可使用
struct QuickRecordOverlay: View {
    @Environment(\.managedObjectContext) private var context
    @State private var isExpanded = false
    @State private var text = ""
    @State private var selectedMood: MoodType = .neutral
    @State private var selectedCategory: EventCategory = .life
    @State private var showConfirmation = false
    @FocusState private var textFocused: Bool

    var body: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                if isExpanded {
                    quickRecordPanel
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    fab
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 90) // above tab bar
        }
    }

    // MARK: - FAB

    private var fab: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                isExpanded = true
                textFocused = true
            }
        } label: {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color("AccentPrimary"), Color("AccentSecondary")],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 56, height: 56)
                    .shadow(color: Color("AccentPrimary").opacity(0.4), radius: 12, y: 4)
                Image(systemName: "plus")
                    .font(.title2.bold())
                    .foregroundColor(.white)
            }
        }
    }

    // MARK: - Quick Record Panel

    private var quickRecordPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("快速记录").font(.headline)
                Spacer()
                Button {
                    withAnimation(.spring()) { isExpanded = false; text = "" }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
            }

            TextField("发生了什么？", text: $text, axis: .vertical)
                .lineLimit(2...5)
                .focused($textFocused)
                .padding(10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            // Mood row
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MoodType.allCases, id: \.rawValue) { mood in
                        Button {
                            selectedMood = mood
                        } label: {
                            Text(mood.emoji)
                                .font(.title3)
                                .padding(6)
                                .background(
                                    selectedMood == mood
                                        ? Color("AccentPrimary").opacity(0.15)
                                        : Color(.systemGray6)
                                )
                                .clipShape(Circle())
                                .overlay {
                                    if selectedMood == mood {
                                        Circle().stroke(Color("AccentPrimary"), lineWidth: 1.5)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Category + Save row
            HStack {
                Picker("", selection: $selectedCategory) {
                    ForEach(EventCategory.allCases, id: \.rawValue) { cat in
                        Label(cat.label, systemImage: cat.icon).tag(cat)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(Color("AccentPrimary"))

                Spacer()

                Button {
                    saveRecord()
                } label: {
                    Label("保存", systemImage: "checkmark")
                        .font(.subheadline.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(text.isEmpty ? Color.gray : Color("AccentPrimary"))
                        .clipShape(Capsule())
                }
                .disabled(text.isEmpty)
            }

            if showConfirmation {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("已记录 \(selectedMood.emoji)").font(.subheadline)
                }
                .transition(.opacity)
            }
        }
        .padding(16)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.12), radius: 20, y: -4)
        .frame(maxWidth: 340)
    }

    // MARK: - Save

    private func saveRecord() {
        guard !text.isEmpty else { return }
        let event = LifeEvent(
            title: String(text.prefix(30)),
            content: text,
            mood: selectedMood,
            category: selectedCategory
        )
        CDLifeEvent.create(from: event, context: context)
        PersistenceController.shared.save()

        withAnimation { showConfirmation = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.spring()) {
                isExpanded = false
                text = ""
                selectedMood = .neutral
                selectedCategory = .life
                showConfirmation = false
            }
        }
    }
}
