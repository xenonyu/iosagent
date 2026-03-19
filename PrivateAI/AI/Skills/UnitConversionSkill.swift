import Foundation

/// Handles unit conversion queries — temperature, length, weight, volume.
/// All conversions run locally with standard formulas. No network needed.
///
/// Supported conversions:
/// - Temperature: °C ↔ °F
/// - Length: km ↔ miles, cm ↔ inches, meters ↔ feet
/// - Weight: kg ↔ lbs, grams ↔ oz
/// - Volume: liters ↔ gallons
struct UnitConversionSkill: ClawSkill {

    let id = "unitConversion"

    func canHandle(intent: QueryIntent) -> Bool {
        if case .unitConversion = intent { return true }
        return false
    }

    func execute(intent: QueryIntent, context: SkillContext, completion: @escaping (String) -> Void) {
        guard case .unitConversion(let value, let fromUnit, let toUnit) = intent else { return }

        guard let result = convert(value: value, from: fromUnit, to: toUnit) else {
            completion("😅 抱歉，暂不支持 \(unitDisplayName(fromUnit)) 到 \(unitDisplayName(toUnit)) 的转换。\n\n📐 支持的转换：\n• 温度：摄氏 ↔ 华氏\n• 长度：公里 ↔ 英里、厘米 ↔ 英寸、米 ↔ 英尺\n• 重量：公斤 ↔ 磅、克 ↔ 盎司\n• 体积：升 ↔ 加仑")
            return
        }

        let fromDisplay = formatValue(value)
        let toDisplay = formatValue(result)
        let fromName = unitDisplayName(fromUnit)
        let toName = unitDisplayName(toUnit)
        let emoji = categoryEmoji(fromUnit)
        let formula = conversionFormula(from: fromUnit, to: toUnit)

        var response = "\(emoji) **\(fromDisplay) \(fromName) = \(toDisplay) \(toName)**"
        if !formula.isEmpty {
            response += "\n\n📝 公式：\(formula)"
        }
        response += "\n\n💡 还需要转换其他单位吗？试试：\n• 「100华氏度转摄氏」\n• 「10公里转英里」\n• 「75公斤转磅」"

        completion(response)
    }

    // MARK: - Conversion Logic

    private func convert(value: Double, from: String, to: String) -> Double? {
        switch (from, to) {
        // Temperature
        case ("celsius", "fahrenheit"):
            return value * 9.0 / 5.0 + 32.0
        case ("fahrenheit", "celsius"):
            return (value - 32.0) * 5.0 / 9.0

        // Length
        case ("km", "miles"):
            return value * 0.621371
        case ("miles", "km"):
            return value * 1.60934
        case ("cm", "inches"):
            return value / 2.54
        case ("inches", "cm"):
            return value * 2.54
        case ("meters", "feet"):
            return value * 3.28084
        case ("feet", "meters"):
            return value / 3.28084

        // Weight
        case ("kg", "lbs"):
            return value * 2.20462
        case ("lbs", "kg"):
            return value / 2.20462
        case ("grams", "oz"):
            return value / 28.3495
        case ("oz", "grams"):
            return value * 28.3495

        // Volume
        case ("liters", "gallons"):
            return value * 0.264172
        case ("gallons", "liters"):
            return value * 3.78541

        default:
            return nil
        }
    }

    // MARK: - Display Helpers

    private func formatValue(_ value: Double) -> String {
        if value == value.rounded() && abs(value) < 1e10 {
            return String(format: "%.0f", value)
        }
        let s = String(format: "%.4f", value)
        var trimmed = s
        while trimmed.hasSuffix("0") { trimmed.removeLast() }
        if trimmed.hasSuffix(".") { trimmed.removeLast() }
        return trimmed
    }

    private func unitDisplayName(_ unit: String) -> String {
        switch unit {
        case "celsius": return "摄氏度(°C)"
        case "fahrenheit": return "华氏度(°F)"
        case "km": return "公里(km)"
        case "miles": return "英里(mi)"
        case "cm": return "厘米(cm)"
        case "inches": return "英寸(in)"
        case "meters": return "米(m)"
        case "feet": return "英尺(ft)"
        case "kg": return "公斤(kg)"
        case "lbs": return "磅(lb)"
        case "grams": return "克(g)"
        case "oz": return "盎司(oz)"
        case "liters": return "升(L)"
        case "gallons": return "加仑(gal)"
        default: return unit
        }
    }

    private func categoryEmoji(_ unit: String) -> String {
        switch unit {
        case "celsius", "fahrenheit": return "🌡️"
        case "km", "miles", "cm", "inches", "meters", "feet": return "📏"
        case "kg", "lbs", "grams", "oz": return "⚖️"
        case "liters", "gallons": return "🫗"
        default: return "📐"
        }
    }

    private func conversionFormula(from: String, to: String) -> String {
        switch (from, to) {
        case ("celsius", "fahrenheit"): return "°F = °C × 9/5 + 32"
        case ("fahrenheit", "celsius"): return "°C = (°F - 32) × 5/9"
        case ("km", "miles"): return "1 km ≈ 0.6214 miles"
        case ("miles", "km"): return "1 mile ≈ 1.6093 km"
        case ("cm", "inches"): return "1 inch = 2.54 cm"
        case ("inches", "cm"): return "1 inch = 2.54 cm"
        case ("meters", "feet"): return "1 m ≈ 3.2808 ft"
        case ("feet", "meters"): return "1 ft ≈ 0.3048 m"
        case ("kg", "lbs"): return "1 kg ≈ 2.2046 lbs"
        case ("lbs", "kg"): return "1 lb ≈ 0.4536 kg"
        case ("grams", "oz"): return "1 oz ≈ 28.35 g"
        case ("oz", "grams"): return "1 oz ≈ 28.35 g"
        case ("liters", "gallons"): return "1 L ≈ 0.2642 gal"
        case ("gallons", "liters"): return "1 gal ≈ 3.7854 L"
        default: return ""
        }
    }
}
