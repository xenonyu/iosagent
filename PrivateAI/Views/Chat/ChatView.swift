import SwiftUI

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @Namespace private var bottomID
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Message list
                ScrollViewReader { proxy in
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

                            // Scroll anchor
                            Color.clear
                                .frame(height: 1)
                                .id(bottomID)
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
                    onVoice: viewModel.toggleVoiceInput
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

// MARK: - Input Bar

struct InputBar: View {
    @Binding var text: String
    let isListening: Bool
    var isFocused: FocusState<Bool>.Binding
    let onSend: () -> Void
    let onVoice: () -> Void
    @State private var micScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 10) {
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
