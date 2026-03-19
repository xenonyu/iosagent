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
        \(greeting)！我是 iosclaw 智能助理 🤖

        我可以在本地处理大部分查询，无需联网即可使用。

        试试这些功能：
        • 「今天走了多少步？」— 健康数据
        • 「帮我记个笔记」— 笔记 / 待办 / 记录
        • 「设个25分钟番茄钟」— 专注计时
        • 「帮我算 128×37」— 计算 / 单位换算
        • 「今天喝了500ml水」— 饮水追踪
        • 或者问我任何其他问题 ✨

        直接打字或语音输入即可。
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

        let engine = ClawEngine(
            context: context,
            healthService: appState.healthService,
            calendarService: appState.calendarService,
            photoService: appState.photoService,
            profile: profile,
            contextMemory: contextMemory
        )

        // Local-first routing: use SkillRouter to determine intent
        let intent = SkillRouter.parse(text)

        // Photo search has dedicated UI handling
        if case .photoSearch(let query) = intent {
            handlePhotoSearch(query: query)
            return
        }

        // For known intents, handle locally via ClawEngine skills
        if !intent.isUnknown {
            engine.respond(to: text, preResolvedIntent: intent) { [weak self] response in
                guard let self else { return }
                let aiMsg = ChatMessage(content: response, isUser: false)
                self.append(message: aiMsg)
                self.persist(message: aiMsg)
                self.contextMemory.add(message: aiMsg)
                self.isThinking = false
            }
            return
        }

        // For unknown intents, try GPT API with full context, fall back to local UnknownSkill
        let recentHistory = contextMemory.recentMessages
        engine.buildGPTPrompt(userQuery: text, conversationHistory: recentHistory) { [weak self] prompt in
            guard let self else { return }
            Task {
                do {
                    let gptReply = try await RawGPTService.shared.ask(prompt)
                    await MainActor.run {
                        let aiMsg = ChatMessage(content: gptReply, isUser: false)
                        self.append(message: aiMsg)
                        self.persist(message: aiMsg)
                        self.contextMemory.add(message: aiMsg)
                        self.isThinking = false
                    }
                } catch {
                    // GPT unavailable — fall back to local UnknownSkill for a graceful response
                    await MainActor.run {
                        engine.respond(to: text, preResolvedIntent: .unknown) { [weak self] localResponse in
                            guard let self else { return }
                            let aiMsg = ChatMessage(content: localResponse, isUser: false)
                            self.append(message: aiMsg)
                            self.persist(message: aiMsg)
                            self.contextMemory.add(message: aiMsg)
                            self.isThinking = false
                        }
                    }
                }
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

    // MARK: - Suggested Questions

    /// 推荐问题列表，根据时间动态调整
    var suggestedQuestions: [String] {
        let hour = Calendar.current.component(.hour, from: Date())
        var base = [
            "帮我总结这周的生活",
            "我最近心情怎么样？",
            "给我推荐送老婆的礼物"
        ]
        if hour < 12 {
            base.insert("今天有什么日历行程？", at: 0)
        } else if hour >= 18 {
            base.insert("今天做了什么运动？", at: 0)
            base.insert("今天去过哪些地方？", at: 1)
        }
        return Array(base.prefix(4))
    }

    // MARK: - Photo Search

    private func handlePhotoSearch(query: String) {
        let searchService = PhotoSearchService(context: context)
        let parsed = searchService.parseQuery(query)
        let results = searchService.search(query: parsed)

        let assetIDs = results.map { $0.assetId }

        if assetIDs.isEmpty {
            let noResultMsg: String
            if searchService.parseQuery(query).location != nil {
                noResultMsg = "📷 没有找到匹配的照片。可能是该地点的照片尚未索引，请先到设置里开启「相册索引」。"
            } else {
                noResultMsg = "📷 没有找到匹配的照片。\n试试其他描述，比如「海边的自拍」「和猫的合照」等。\n\n如果还未开始索引，请到设置里开启「相册索引」。"
            }
            let aiMsg = ChatMessage(content: noResultMsg, isUser: false)
            append(message: aiMsg)
            persist(message: aiMsg)
            contextMemory.add(message: aiMsg)
        } else {
            let locationHint = parsed.locationName.isEmpty ? "" : "在\(parsed.locationName)附近"
            let countText = "找到 \(assetIDs.count) 张\(locationHint)匹配的照片"
            let aiMsg = ChatMessage(content: "📷 \(countText)，向你展示搜索结果：", isUser: false)
            append(message: aiMsg)
            persist(message: aiMsg)
            contextMemory.add(message: aiMsg)

            photoSearchResults = assetIDs
            showPhotoResults = true
        }

        isThinking = false
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
