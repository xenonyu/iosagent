import Foundation
import CoreData
import Combine

final class ChatViewModel: ObservableObject {

    // MARK: - Published

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isThinking: Bool = false
    @Published var isListening: Bool = false

    // MARK: - Dependencies

    private let context: NSManagedObjectContext
    private let speechService: SpeechService
    private let appState: AppState
    private let contextMemory = ContextMemory()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(context: NSManagedObjectContext, appState: AppState) {
        self.context = context
        self.appState = appState
        self.speechService = appState.speechService

        loadMessages()
        bindSpeech()
    }

    // MARK: - Loading

    private func loadMessages() {
        messages = CDChatMessage.fetchAll(in: context)

        if messages.isEmpty {
            let welcome = ChatMessage(
                content: buildWelcomeMessage(),
                isUser: false
            )
            messages.append(welcome)
        }
    }

    private func buildWelcomeMessage() -> String {
        let hour = Calendar.current.component(.hour, from: Date())
        let greeting: String
        switch hour {
        case 6..<12: greeting = "早上好"
        case 12..<18: greeting = "下午好"
        case 18..<22: greeting = "晚上好"
        default: greeting = "夜深了，还没睡呀"
        }

        return """
        \(greeting)！我是你的私人 AI 助理 🤖

        我的所有数据都存在你手机本地，绝对私密。

        你可以问我：
        • 「我上周做了什么运动？」
        • 「最近去过哪些地方？」
        • 「帮我总结这个月的生活」
        • 「给老婆推荐礼物」

        或者直接告诉我你今天做了什么，我会帮你记录下来。
        """
    }

    // MARK: - Sending

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMsg = ChatMessage(content: text, isUser: true)
        append(message: userMsg)
        persist(message: userMsg)
        contextMemory.add(message: userMsg)

        inputText = ""
        isThinking = true

        // Build profile from CoreData
        let profile = CDUserProfile.fetchOrCreate(in: context).toProfileData()

        // Resolve intent with context memory (handles follow-ups like "那昨天呢?")
        let resolvedIntent = contextMemory.resolveIntent(from: text)
        contextMemory.setLastIntent(resolvedIntent)

        let engine = LocalAIEngine(
            context: context,
            healthService: appState.healthService,
            calendarService: appState.calendarService,
            photoService: appState.photoService,
            profile: profile,
            contextMemory: contextMemory
        )

        // Small delay to feel more natural
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            engine.respond(to: text, preResolvedIntent: resolvedIntent) { [weak self] response in
                guard let self else { return }
                let aiMsg = ChatMessage(content: response, isUser: false)
                self.append(message: aiMsg)
                self.persist(message: aiMsg)
                self.contextMemory.add(message: aiMsg)
                self.isThinking = false
            }
        }
    }

    // MARK: - Voice Input

    func toggleVoiceInput() {
        if speechService.isListening {
            speechService.stopListening()
            // Transfer transcript to input
            if !speechService.transcript.isEmpty {
                inputText = speechService.transcript
            }
            speechService.transcript = ""
        } else {
            speechService.transcript = ""
            speechService.startListening()
        }
    }

    private func bindSpeech() {
        speechService.$isListening
            .receive(on: DispatchQueue.main)
            .assign(to: &$isListening)

        speechService.$transcript
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                if !text.isEmpty { self?.inputText = text }
            }
            .store(in: &cancellables)
    }

    // MARK: - Helpers

    private func append(message: ChatMessage) {
        DispatchQueue.main.async {
            self.messages.append(message)
        }
    }

    private func persist(message: ChatMessage) {
        CDChatMessage.create(from: message, context: context)
        PersistenceController.shared.save()
    }

    func clearHistory() {
        CDChatMessage.deleteAll(in: context)
        PersistenceController.shared.save()
        messages = []
        let welcome = ChatMessage(content: buildWelcomeMessage(), isUser: false)
        messages.append(welcome)
    }
}
