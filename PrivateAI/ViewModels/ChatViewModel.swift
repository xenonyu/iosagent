import Foundation
import CoreData
import Combine

final class ChatViewModel: ObservableObject {

    // MARK: - Published

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isThinking: Bool = false
    @Published var isListening: Bool = false
    @Published var photoSearchResults: [String] = []  // PHAsset IDs
    @Published var showPhotoResults: Bool = false

    // MARK: - Dependencies

    private let context: NSManagedObjectContext
    private let speechService: SpeechService
    private let appState: AppState
    private let contextBuilder: GPTContextBuilder
    private var conversationHistory: [ChatMessage] = []
    private let maxHistory = 12
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(context: NSManagedObjectContext, appState: AppState) {
        self.context = context
        self.appState = appState
        self.speechService = appState.speechService

        let profile = CDUserProfile.fetchOrCreate(in: context).toProfileData()
        self.contextBuilder = GPTContextBuilder(
            context: context,
            healthService: appState.healthService,
            calendarService: appState.calendarService,
            photoService: appState.photoService,
            locationService: appState.locationService,
            profile: profile
        )

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

        // Restore conversation history from persisted messages so GPT retains
        // multi-turn context across app restarts.
        // Filter out error messages (⚠️ prefix) — these were persisted for display
        // but should not be sent to GPT as previous "assistant" responses.
        conversationHistory = messages
            .filter { $0.isUser || !$0.content.hasPrefix("⚠️") }
            .suffix(maxHistory)
            .map { $0 }
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
        \(greeting)！我是 iosclaw 🤖

        我是你的私人数据助手，能帮你了解自己的真实生活数据。

        试试问我：
        • 「今天走了多少步？」— 健康 & 运动
        • 「我睡得怎么样？」— 睡眠分析
        • 「今天有什么安排？」— 日程查看
        • 「最近去了哪些地方？」— 足迹回顾
        • 「帮我找海边拍的照片」— 照片搜索
        • 「这周过得怎么样？」— 生活总结
        """
    }

    // MARK: - Sending

    func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let userMsg = ChatMessage(content: text, isUser: true)
        append(message: userMsg)
        persist(message: userMsg)
        addToHistory(userMsg)

        inputText = ""
        isThinking = true

        // Photo search detection — populate grid in parallel with GPT response
        if isPhotoSearchQuery(text) {
            populatePhotoGrid(query: text)
        }

        // ALL queries go to GPT via RawGPTService
        let profile = CDUserProfile.fetchOrCreate(in: context).toProfileData()
        contextBuilder.updateProfile(profile)

        contextBuilder.buildPrompt(userQuery: text, conversationHistory: conversationHistory) { [weak self] prompt in
            guard let self else { return }
            Task {
                do {
                    let reply = try await RawGPTService.shared.ask(prompt)
                    await MainActor.run {
                        let aiMsg = ChatMessage(content: reply, isUser: false)
                        self.append(message: aiMsg)
                        self.persist(message: aiMsg)
                        self.addToHistory(aiMsg)
                        self.isThinking = false
                    }
                } catch {
                    await MainActor.run {
                        // Remove the orphaned user message from conversation history.
                        // Without a paired assistant response, GPT would see a dangling
                        // question on the next query and may try to answer it alongside
                        // the new question, causing confused multi-topic responses.
                        if let lastIdx = self.conversationHistory.lastIndex(where: { $0.isUser && $0.content == text }) {
                            self.conversationHistory.remove(at: lastIdx)
                        }

                        let errorText = self.friendlyErrorMessage(error)
                        let errorMsg = ChatMessage(
                            content: errorText,
                            isUser: false
                        )
                        self.append(message: errorMsg)
                        self.persist(message: errorMsg)
                        self.isThinking = false
                    }
                }
            }
        }
    }

    // MARK: - Photo Search Detection

    /// Simple keyword check to detect photo search queries.
    /// Uses specific photo keywords, and only triggers on generic action words
    /// (帮我找, 给我找, etc.) when combined with photo-related context — avoids
    /// false positives like "帮我找明天的会议" triggering a photo grid.
    private func isPhotoSearchQuery(_ text: String) -> Bool {
        let lower = text.lowercased()
        let specificKeywords = [
            "找照片", "搜照片", "找图片", "搜图片", "找找照片", "照片搜索",
            "find photo", "search photo", "show me photo",
            "的照片", "的图片", "的相片",
            "photo of", "picture of"
        ]
        if specificKeywords.contains(where: { lower.contains($0) }) { return true }

        // Generic action words only count when query also mentions photos
        let genericKeywords = ["帮我找", "给我找", "搜一下", "找一下"]
        let photoContext = ["照片", "图片", "相片", "photo", "picture", "拍", "自拍", "截图", "视频"]
        return genericKeywords.contains(where: { lower.contains($0) })
            && photoContext.contains(where: { lower.contains($0) })
    }

    // MARK: - Voice Input

    func toggleVoiceInput() {
        if speechService.isListening {
            speechService.stopListening()
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

    // MARK: - Suggested Questions

    var suggestedQuestions: [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        var base = [
            "帮我总结这周的生活",
            "我最近心情怎么样？",
            "帮我找海边拍的照片"
        ]
        if hour < 12 {
            base.insert("今天有什么日历行程？", at: 0)
        } else if hour >= 18 {
            base.insert("今天做了什么运动？", at: 0)
            base.insert("今天去过哪些地方？", at: 1)
        }
        return Array(base.prefix(4))
    }

    // MARK: - Photo Search Grid

    private func populatePhotoGrid(query: String) {
        let searchService = PhotoSearchService(context: context)
        let parsed = searchService.parseQuery(query)
        let results = searchService.search(query: parsed)
        let assetIDs = results.map { $0.assetId }

        guard !assetIDs.isEmpty else { return }

        DispatchQueue.main.async {
            self.photoSearchResults = assetIDs
            self.showPhotoResults = true
        }
    }

    // MARK: - Conversation History

    private func addToHistory(_ message: ChatMessage) {
        conversationHistory.append(message)
        if conversationHistory.count > maxHistory {
            conversationHistory.removeFirst(conversationHistory.count - maxHistory)
        }
    }

    // MARK: - Error Handling

    private func friendlyErrorMessage(_ error: Error) -> String {
        let urlError = error as? URLError
        switch urlError?.code {
        case .timedOut:
            return "⚠️ 请求超时了，可能是网络较慢。请稍后再试。"
        case .notConnectedToInternet, .networkConnectionLost:
            return "⚠️ 当前无网络连接，请检查 Wi-Fi 或蜂窝数据后重试。"
        case .cannotParseResponse:
            return "⚠️ 服务器返回了意外的格式，请稍后再试。"
        case .badServerResponse:
            return "⚠️ 服务器暂时不可用，请稍后再试。"
        default:
            return "⚠️ 连接失败，请检查网络后重试。"
        }
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
        conversationHistory = []
        let welcome = ChatMessage(content: buildWelcomeMessage(), isUser: false)
        messages.append(welcome)
    }
}
