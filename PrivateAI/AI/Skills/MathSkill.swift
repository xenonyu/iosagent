import Foundation

/// Handles math and calculator queries — evaluates arithmetic expressions locally.
/// Supports +, -, *, /, parentheses, and Chinese operators (×, ÷, 加上, 减去, 乘以, 除以).
struct MathSkill: ClawSkill {

    let id = "math"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .math = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .math(let expression) = intent else { return }

        let normalized = normalizeExpression(expression)

        guard !normalized.isEmpty else {
            completion("🔢 请输入一个算术表达式，例如：**3 + 5 × 2** 或 **计算 100 ÷ 4**")
            return
        }

        if let result = evaluate(normalized) {
            let formatted = formatResult(result)
            let displayExpr = prettyExpression(expression)
            completion("🔢 **\(displayExpr) = \(formatted)**\n\n✨ 计算完成！还有其他需要算的吗？")
        } else {
            completion("😅 抱歉，无法计算「\(expression)」\n\n请检查表达式是否正确，支持 +、-、×、÷ 和括号。\n例如：**12 × 3 + 5** 或 **(100 - 20) ÷ 4**")
        }
    }

    // MARK: - Expression Normalization

    /// Converts Chinese math operators and common variations to standard arithmetic.
    private func normalizeExpression(_ expr: String) -> String {
        var s = expr
        // Chinese operators → standard
        s = s.replacingOccurrences(of: "×", with: "*")
        s = s.replacingOccurrences(of: "÷", with: "/")
        s = s.replacingOccurrences(of: "x", with: "*") // lowercase x as multiply (only between digits)
        s = s.replacingOccurrences(of: "X", with: "*")
        // Chinese verbal operators
        s = s.replacingOccurrences(of: "加上", with: "+")
        s = s.replacingOccurrences(of: "加", with: "+")
        s = s.replacingOccurrences(of: "减去", with: "-")
        s = s.replacingOccurrences(of: "减", with: "-")
        s = s.replacingOccurrences(of: "乘以", with: "*")
        s = s.replacingOccurrences(of: "乘", with: "*")
        s = s.replacingOccurrences(of: "除以", with: "/")
        s = s.replacingOccurrences(of: "除", with: "/")
        // Chinese parentheses
        s = s.replacingOccurrences(of: "（", with: "(")
        s = s.replacingOccurrences(of: "）", with: ")")
        // Power
        s = s.replacingOccurrences(of: "的平方", with: "^2")
        s = s.replacingOccurrences(of: "的立方", with: "^3")
        // Remove spaces for cleaner eval
        s = s.replacingOccurrences(of: " ", with: "")
        // Strip any trailing equals / question marks
        s = s.replacingOccurrences(of: "[=？?]+$", with: "", options: .regularExpression)
        return s
    }

    // MARK: - Evaluation (NSExpression-based)

    /// Evaluates a math expression string. Uses NSExpression for safety (no arbitrary code exec).
    /// Handles ^ (power) by pre-processing to pow() calls.
    private func evaluate(_ expr: String) -> Double? {
        // Handle power operator: replace a^b with special handling
        var processed = preprocessPower(expr)

        // Validate: only allow safe characters
        let allowed = CharacterSet.decimalDigits
            .union(CharacterSet(charactersIn: "+-*/().%"))
        let filtered = processed.unicodeScalars.filter { allowed.contains($0) || $0 == " " }
        guard filtered.count == processed.unicodeScalars.count else { return nil }

        // Guard against empty or operator-only expressions
        guard processed.contains(where: { $0.isNumber }) else { return nil }

        // Handle modulo: NSExpression doesn't support %, convert to manual
        if processed.contains("%") {
            return evaluateWithModulo(processed)
        }

        // Use NSExpression for safe evaluation
        do {
            let nsExpr = NSExpression(format: processed)
            if let result = nsExpr.expressionValue(with: nil, context: nil) as? NSNumber {
                let dbl = result.doubleValue
                guard dbl.isFinite else { return nil }
                return dbl
            }
        } catch {
            return nil
        }
        return nil
    }

    /// Pre-process power expressions: 2^3 → pow(2,3)
    /// Simple single-level support.
    private func preprocessPower(_ expr: String) -> String {
        guard expr.contains("^") else { return expr }

        // Match number^number patterns
        guard let regex = try? NSRegularExpression(
            pattern: "([\\d.]+)\\^([\\d.]+)",
            options: []
        ) else { return expr }

        var result = expr
        let ns = result as NSString
        // Process matches in reverse to preserve indices
        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let base = ns.substring(with: match.range(at: 1))
            let exp = ns.substring(with: match.range(at: 2))
            if let b = Double(base), let e = Double(exp) {
                let powResult = pow(b, e)
                result = (result as NSString).replacingCharacters(in: match.range, with: "\(powResult)")
            }
        }
        return result
    }

    /// Handle expressions with % (modulo) operator.
    private func evaluateWithModulo(_ expr: String) -> Double? {
        // Simple case: a % b
        let parts = expr.split(separator: "%", maxSplits: 1)
        guard parts.count == 2,
              let left = evaluate(String(parts[0])),
              let right = evaluate(String(parts[1])),
              right != 0 else { return nil }
        return left.truncatingRemainder(dividingBy: right)
    }

    // MARK: - Formatting

    /// Formats a double nicely: integers show without decimals, others show up to 4 places.
    private func formatResult(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e12 {
            return String(format: "%.0f", value)
        }
        // Remove trailing zeros
        let s = String(format: "%.6f", value)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    /// Makes the original expression prettier for display.
    private func prettyExpression(_ expr: String) -> String {
        var s = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        // Normalize multipliers for display
        s = s.replacingOccurrences(of: "*", with: " × ")
        s = s.replacingOccurrences(of: "/", with: " ÷ ")
        s = s.replacingOccurrences(of: "+", with: " + ")
        s = s.replacingOccurrences(of: "-", with: " - ")
        // Clean up double spaces
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
