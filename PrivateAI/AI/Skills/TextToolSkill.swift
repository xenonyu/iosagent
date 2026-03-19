import Foundation

/// Skill for text manipulation utilities: word count, case conversion,
/// reverse, whitespace cleanup, and character frequency analysis.
/// All processing is purely local with no network calls.
struct TextToolSkill: ClawSkill {
    let id = "textTool"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .textTool = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .textTool(let action, let content) = intent else {
            completion("无法处理该请求。")
            return
        }

        switch action {
        case .help:
            completion(helpMessage())
        case .wordCount:
            completion(wordCount(content))
        case .toUppercase:
            completion(toUppercase(content))
        case .toLowercase:
            completion(toLowercase(content))
        case .reverse:
            completion(reverseText(content))
        case .removeSpaces:
            completion(removeSpaces(content))
        case .charFrequency:
            completion(charFrequency(content))
        }
    }

    // MARK: - Help

    private func helpMessage() -> String {
        """
        📝 文本工具箱

        我可以帮你处理文本，试试这些：

        📊 字数统计
        「统计字数：你好世界」

        🔠 大小写转换
        「转大写：hello world」
        「转小写：HELLO WORLD」

        🔄 文本反转
        「反转：你好世界」

        ✂️ 去除空格
        「去空格：hello   world」

        📈 字符频率
        「字符频率：hello world」

        在指令后面加上冒号或引号包裹文本即可！
        """
    }

    // MARK: - Word Count

    private func wordCount(_ text: String) -> String {
        guard !text.isEmpty else {
            return "请提供要统计的文本。例如：「统计字数：你好世界」"
        }

        let charCount = text.count
        let charNoSpaces = text.filter { !$0.isWhitespace }.count

        // Chinese character count
        let chineseCount = text.unicodeScalars.filter { isChinese($0) }.count

        // English word count (split by whitespace, filter non-empty)
        let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let wordCount = words.count

        // Line count
        let lines = text.components(separatedBy: .newlines)
        let lineCount = lines.count

        var result = "📊 文本统计结果\n\n"
        result += "📝 原文：\(text.prefix(50))\(text.count > 50 ? "..." : "")\n\n"
        result += "• 总字符数：\(charCount)\n"
        result += "• 不含空格：\(charNoSpaces)\n"
        if chineseCount > 0 {
            result += "• 中文字符：\(chineseCount)\n"
        }
        result += "• 词/词组数：\(wordCount)\n"
        if lineCount > 1 {
            result += "• 行数：\(lineCount)\n"
        }

        return result
    }

    // MARK: - Case Conversion

    private func toUppercase(_ text: String) -> String {
        guard !text.isEmpty else {
            return "请提供要转换的文本。例如：「转大写：hello world」"
        }
        let result = text.uppercased()
        return "🔠 转换结果\n\n\(result)\n\n已将文本转为大写，长按可复制。"
    }

    private func toLowercase(_ text: String) -> String {
        guard !text.isEmpty else {
            return "请提供要转换的文本。例如：「转小写：HELLO WORLD」"
        }
        let result = text.lowercased()
        return "🔡 转换结果\n\n\(result)\n\n已将文本转为小写，长按可复制。"
    }

    // MARK: - Reverse

    private func reverseText(_ text: String) -> String {
        guard !text.isEmpty else {
            return "请提供要反转的文本。例如：「反转：你好世界」"
        }
        let reversed = String(text.reversed())
        return "🔄 反转结果\n\n原文：\(text)\n反转：\(reversed)"
    }

    // MARK: - Remove Spaces

    private func removeSpaces(_ text: String) -> String {
        guard !text.isEmpty else {
            return "请提供要处理的文本。例如：「去空格：hello   world」"
        }
        // Collapse multiple spaces into one
        let collapsed = text.components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "✂️ 处理结果\n\n\(collapsed)\n\n已去除多余空格。"
    }

    // MARK: - Character Frequency

    private func charFrequency(_ text: String) -> String {
        guard !text.isEmpty else {
            return "请提供要分析的文本。例如：「字符频率：hello world」"
        }

        var freq: [Character: Int] = [:]
        for ch in text where !ch.isWhitespace {
            freq[ch, default: 0] += 1
        }

        // Sort by frequency descending, take top 15
        let sorted = freq.sorted { $0.value > $1.value }.prefix(15)

        var result = "📈 字符频率分析\n\n"
        result += "📝 原文：\(text.prefix(40))\(text.count > 40 ? "..." : "")\n\n"

        let total = freq.values.reduce(0, +)
        for (ch, count) in sorted {
            let pct = Double(count) / Double(total) * 100
            let bar = String(repeating: "█", count: max(1, Int(pct / 5)))
            result += "「\(ch)」\(bar) \(count)次 (\(String(format: "%.1f", pct))%)\n"
        }

        if freq.count > 15 {
            result += "\n...还有 \(freq.count - 15) 个不同字符"
        }

        return result
    }

    // MARK: - Helpers

    private func isChinese(_ scalar: Unicode.Scalar) -> Bool {
        // CJK Unified Ideographs
        (0x4E00...0x9FFF).contains(scalar.value) ||
        // CJK Extension A
        (0x3400...0x4DBF).contains(scalar.value) ||
        // CJK Extension B
        (0x20000...0x2A6DF).contains(scalar.value)
    }
}
