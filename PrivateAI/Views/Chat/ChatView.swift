import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Namespace private var bottomID
    @FocusState private var inputFocused: Bool
    @State private var isAtBottom: Bool = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Message list
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(viewModel.messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                            }

                            // Show suggestions after welcome message
                            if viewModel.messages.count == 1 {
                                SuggestionsView(questions: viewModel.suggestedQuestions) { q in
                                    viewModel.inputText = q
                                    viewModel.sendMessage()
                                }
                                .id("suggestions")
                            }

                            // Contextual follow-up suggestions after AI response
                            if viewModel.messages.count > 1,
                               !viewModel.isThinking,
                               let last = viewModel.messages.last, !last.isUser,
                               !viewModel.followUpSuggestions.isEmpty {
                                FollowUpChipsView(suggestions: viewModel.followUpSuggestions) { q in
                                    viewModel.inputText = q
                                    viewModel.sendMessage()
                                }
                                .id("followUps")
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }

                            // Photo search results strip
                            if !viewModel.photoSearchResults.isEmpty {
                                PhotoResultsStrip(
                                    assetIDs: viewModel.photoSearchResults,
                                    onShowAll: { viewModel.showPhotoResults = true }
                                )
                                .padding(.leading, 40)
                            }

                            if viewModel.isThinking {
                                ThinkingBubble()
                            }

                            // Scroll anchor — also tracks visibility to toggle scroll-to-bottom button
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
                                .onAppear { isAtBottom = true }
                                .onDisappear { isAtBottom = false }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onTapGesture { inputFocused = false }
                    .onReceive(viewModel.$messages) { _ in
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }
                    .onReceive(viewModel.$isThinking) { _ in
                        withAnimation(.easeOut(duration: 0.3)) {
                            proxy.scrollTo(bottomID, anchor: .bottom)
                        }
                    }

                    // Floating scroll-to-bottom button
                    if !isAtBottom {
                        ScrollToBottomButton {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(bottomID, anchor: .bottom)
                            }
                        }
                        .padding(.trailing, 12)
                        .padding(.bottom, 8)
                        .transition(.scale.combined(with: .opacity))
                    }
                    } // ZStack
                }

                Divider()

                // Input bar
                InputBar(
                    text: $viewModel.inputText,
                    isListening: viewModel.isListening,
                    isFocused: $inputFocused,
                    onSend: {
                        viewModel.sendMessage()
                        inputFocused = false
                    },
                    onVoice: viewModel.toggleVoiceInput,
                    onQuickAction: { command in
                        viewModel.inputText = command
                        viewModel.sendMessage()
                    }
                )
            }
            .navigationTitle("AI 助理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button(role: .destructive) {
                            viewModel.clearHistory()
                        } label: {
                            Label("清空对话", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { inputFocused = false }
                        .fontWeight(.medium)
                }
            }
            .sheet(isPresented: $viewModel.showPhotoResults) {
                PhotoSearchResultView(assetIDs: viewModel.photoSearchResults)
            }
        }
    }
}

// MARK: - Thinking indicator

struct ThinkingBubble: View {
    @State private var opacity: Double = 0.4

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            // AI avatar
            Circle()
                .fill(Color("AccentPrimary"))
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "brain")
                        .font(.caption)
                        .foregroundColor(.white)
                }

            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: 8, height: 8)
                        .opacity(opacity)
                        .animation(
                            .easeInOut(duration: 0.6)
                            .repeatForever(autoreverses: true)
                            .delay(Double(i) * 0.2),
                            value: opacity
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 18))

            Spacer()
        }
        .onAppear { opacity = 1.0 }
    }
}

// MARK: - Suggestions View

struct SuggestionsView: View {
    let questions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你可以问我：")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.leading, 44)

            ForEach(questions, id: \.self) { q in
                Button {
                    onSelect(q)
                } label: {
                    Text(q)
                        .font(.subheadline)
                        .foregroundColor(Color("AccentPrimary"))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color("AccentPrimary").opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.leading, 44)
            }
        }
    }
}

// MARK: - Follow-up Chips

struct FollowUpChipsView: View {
    let suggestions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(suggestions, id: \.self) { suggestion in
                    Button {
                        onSelect(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.footnote)
                            .foregroundColor(Color("AccentPrimary"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(Color("AccentPrimary").opacity(0.3), lineWidth: 1)
                                    .background(
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(Color("AccentPrimary").opacity(0.06))
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 44)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - Scroll To Bottom Button

struct ScrollToBottomButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Color("AccentPrimary"))
                .frame(width: 36, height: 36)
                .background(.ultraThinMaterial)
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Quick Action Menu

struct QuickActionMenu: View {
    let onSelect: (String) -> Void

    private struct QuickAction: Identifiable {
        let id = UUID()
        let icon: String
        let label: String
        let command: String
        let color: Color
    }

    private let actions: [[QuickAction]] = [
        [
            QuickAction(icon: "note.text", label: "记笔记", command: "帮我记个笔记", color: .orange),
            QuickAction(icon: "checklist", label: "待办", command: "查看待办清单", color: .blue),
            QuickAction(icon: "timer", label: "番茄钟", command: "开始一个25分钟番茄钟", color: .red),
            QuickAction(icon: "drop.fill", label: "喝水", command: "记录喝了500ml水", color: .cyan),
        ],
        [
            QuickAction(icon: "heart.fill", label: "健康", command: "今天的健康数据", color: .pink),
            QuickAction(icon: "face.smiling", label: "心情", command: "帮我记录今天心情", color: .yellow),
            QuickAction(icon: "calendar", label: "日程", command: "今天有什么安排？", color: .purple),
            QuickAction(icon: "text.quote", label: "名言", command: "给我一句名言", color: .green),
        ],
        [
            QuickAction(icon: "function", label: "计算", command: "帮我算", color: .indigo),
            QuickAction(icon: "wind", label: "呼吸", command: "做一次呼吸练习", color: .teal),
            QuickAction(icon: "bell.fill", label: "提醒", command: "设一个提醒", color: .orange),
            QuickAction(icon: "yensign.circle", label: "记账", command: "记一笔支出", color: .mint),
        ],
    ]

    var body: some View {
        VStack(spacing: 12) {
            // Header
            HStack {
                Text("快捷操作")
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)

            // Action grid
            ForEach(Array(actions.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row) { action in
                        Button {
                            onSelect(action.command)
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 20))
                                    .foregroundColor(action.color)
                                    .frame(width: 44, height: 44)
                                    .background(action.color.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Text(action.label)
                                    .font(.caption2)
                                    .foregroundColor(.primary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Input Bar

struct InputBar: View {
    @Binding var text: String
    let isListening: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onVoice: () -> Void
    var onQuickAction: ((String) -> Void)?
    @State private var micScale: CGFloat = 1.0
    @State private var showQuickActions: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Quick action panel (above input bar)
            if showQuickActions {
                QuickActionMenu { command in
                    withAnimation(.easeOut(duration: 0.2)) {
                        showQuickActions = false
                    }
                    onQuickAction?(command)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))

                Divider()
            }

            HStack(spacing: 10) {
                // Quick action toggle button
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showQuickActions.toggle()
                        if showQuickActions {
                            isFocused.wrappedValue = false
                        }
                    }
                } label: {
                    Image(systemName: showQuickActions ? "xmark.circle.fill" : "plus.circle.fill")
                        .font(.title2)
                        .foregroundColor(showQuickActions ? .secondary : Color("AccentPrimary"))
                        .rotationEffect(.degrees(showQuickActions ? 90 : 0))
                }

                // Voice button
                Button(action: onVoice) {
                    Image(systemName: isListening ? "waveform.circle.fill" : "mic.circle.fill")
                        .font(.title2)
                        .foregroundColor(isListening ? .red : Color("AccentPrimary"))
                        .scaleEffect(micScale)
                        .animation(
                            isListening
                                ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true)
                                : .default,
                            value: micScale
                        )
                }
                .onChange(of: isListening) { listening in
                    micScale = listening ? 1.2 : 1.0
                }

                // Text field
                TextField(isListening ? "正在聆听..." : "问我任何事...", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused(isFocused)
                    .onSubmit { onSend() }
                    .onTapGesture {
                        if showQuickActions {
                            withAnimation(.easeOut(duration: 0.2)) {
                                showQuickActions = false
                            }
                        }
                    }

                // Send button
                Button(action: onSend) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title2)
                        .foregroundColor(text.isEmpty ? .secondary : Color("AccentPrimary"))
                }
                .disabled(text.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
    }
}
