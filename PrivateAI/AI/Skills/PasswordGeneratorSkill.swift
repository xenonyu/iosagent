import Foundation

/// Generates secure random passwords entirely on-device.
/// Supports configurable length, character sets, and PIN codes.
/// Perfect for a privacy-first local assistant — nothing leaves the device.
struct PasswordGeneratorSkill: ClawSkill {

    let id = "passwordGenerator"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .passwordGen = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .passwordGen(let type) = intent else { return }

        switch type {
        case .standard(let length):
            let pwd = generatePassword(length: length, charset: .standard)
            let strength = evaluateStrength(length: length, charset: .standard)
            completion(formatResult(password: pwd, length: length, type: "标准密码", strength: strength))

        case .strong(let length):
            let pwd = generatePassword(length: length, charset: .strong)
            let strength = evaluateStrength(length: length, charset: .strong)
            completion(formatResult(password: pwd, length: length, type: "强密码（含特殊字符）", strength: strength))

        case .pin(let digits):
            let pwd = generatePIN(digits: digits)
            completion(formatPINResult(pin: pwd, digits: digits))

        case .memorable:
            let pwd = generateMemorable()
            completion(formatMemorableResult(password: pwd))

        case .overview:
            completion(overviewResponse())
        }
    }

    // MARK: - Character Sets

    private enum Charset {
        case standard  // letters + digits
        case strong    // letters + digits + symbols
    }

    private let lowercase = "abcdefghijklmnopqrstuvwxyz"
    private let uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
    private let digits = "0123456789"
    private let symbols = "!@#$%^&*()-_=+[]{}|;:,.<>?"

    // MARK: - Generation

    private func generatePassword(length: Int, charset: Charset) -> String {
        let len = max(6, min(length, 64))
        var pool: String
        switch charset {
        case .standard:
            pool = lowercase + uppercase + digits
        case .strong:
            pool = lowercase + uppercase + digits + symbols
        }

        let poolChars = Array(pool)
        var result: [Character] = []

        // Guarantee at least one from each category
        result.append(randomChar(from: lowercase))
        result.append(randomChar(from: uppercase))
        result.append(randomChar(from: digits))
        if charset == .strong {
            result.append(randomChar(from: symbols))
        }

        // Fill remaining
        let remaining = len - result.count
        for _ in 0..<remaining {
            let idx = Int.random(in: 0..<poolChars.count)
            result.append(poolChars[idx])
        }

        // Shuffle to avoid predictable prefix
        result.shuffle()
        return String(result)
    }

    private func generatePIN(digits count: Int) -> String {
        let len = max(4, min(count, 12))
        let digitChars = Array(digits)
        return String((0..<len).map { _ in digitChars[Int.random(in: 0..<digitChars.count)] })
    }

    private func generateMemorable() -> String {
        // Generate a pattern: Word-Digits-Word-Symbol
        let words = [
            "apple", "brave", "cloud", "dream", "eagle", "flame", "grace", "heart",
            "ivory", "jewel", "knack", "light", "magic", "noble", "ocean", "pearl",
            "quest", "river", "solar", "tiger", "ultra", "vivid", "whale", "xenon",
            "youth", "zebra", "amber", "bloom", "cedar", "delta", "ember", "forge",
            "gleam", "Haven", "index", "lunar", "maple", "nexus", "orbit", "prism",
            "radar", "spark", "tempo", "unity", "vault", "wind", "pixel", "crisp",
            "frost", "stone", "steel", "swift", "blaze", "drift", "crest", "shade"
        ]
        let w1 = words[Int.random(in: 0..<words.count)].capitalized
        let w2 = words[Int.random(in: 0..<words.count)].capitalized
        let num = Int.random(in: 10...99)
        let syms = Array("!@#$%&*")
        let sym = syms[Int.random(in: 0..<syms.count)]
        return "\(w1)\(num)\(w2)\(sym)"
    }

    private func randomChar(from str: String) -> Character {
        let chars = Array(str)
        return chars[Int.random(in: 0..<chars.count)]
    }

    // MARK: - Strength Evaluation

    private func evaluateStrength(length: Int, charset: Charset) -> String {
        let score: Int
        switch charset {
        case .standard:
            if length >= 16 { score = 4 }
            else if length >= 12 { score = 3 }
            else if length >= 8 { score = 2 }
            else { score = 1 }
        case .strong:
            if length >= 16 { score = 5 }
            else if length >= 12 { score = 4 }
            else if length >= 8 { score = 3 }
            else { score = 2 }
        }

        switch score {
        case 5: return "🟢🟢🟢🟢🟢 极强"
        case 4: return "🟢🟢🟢🟢⚪ 很强"
        case 3: return "🟢🟢🟢⚪⚪ 中等"
        case 2: return "🟡🟡⚪⚪⚪ 较弱"
        default: return "🔴⚪⚪⚪⚪ 弱"
        }
    }

    // MARK: - Response Formatting

    private func formatResult(password: String, length: Int, type: String, strength: String) -> String {
        """
        🔐 已为你生成\(type)：

        `\(password)`

        📏 长度：\(length) 位
        💪 强度：\(strength)

        ⚡ 提示：密码已在本地生成，绝不会上传到任何服务器。建议复制后立即使用。

        💡 其他选项：
        • 说「生成强密码」→ 包含特殊字符
        • 说「生成20位密码」→ 指定长度
        • 说「生成PIN码」→ 纯数字
        • 说「生成好记的密码」→ 易记单词组合
        """
    }

    private func formatPINResult(pin: String, digits: Int) -> String {
        """
        🔢 已为你生成 \(digits) 位 PIN 码：

        `\(pin)`

        ⚠️ PIN 码安全性较低，建议仅用于简单场景（如手机解锁、快捷支付）。
        需要更安全的密码？说「生成强密码」。

        ⚡ 本地生成，数据不会离开你的设备。
        """
    }

    private func formatMemorableResult(password: String) -> String {
        """
        🧠 已为你生成易记密码：

        `\(password)`

        📏 长度：\(password.count) 位
        💡 格式：单词 + 数字 + 单词 + 符号，既安全又好记

        ⚡ 本地生成，数据不会离开你的设备。
        """
    }

    private func overviewResponse() -> String {
        """
        🔐 密码生成器 — 100% 本地生成，隐私安全

        我可以帮你生成以下类型的密码：

        🔑 **标准密码**（字母+数字）
          → 说「生成密码」或「给我一个密码」

        🛡 **强密码**（字母+数字+特殊字符）
          → 说「生成强密码」或「安全密码」

        🔢 **PIN 码**（纯数字）
          → 说「生成PIN码」或「生成6位数字密码」

        🧠 **易记密码**（单词组合）
          → 说「好记的密码」或「容易记住的密码」

        📏 **自定义长度**
          → 说「生成20位密码」

        所有密码在你的 iPhone 本地生成，绝不会上传到任何地方！🔒
        """
    }
}
