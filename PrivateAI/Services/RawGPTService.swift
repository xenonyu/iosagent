import Foundation

/// Calls the MealMind rawGPT backend with a full-context prompt.
/// Falls back gracefully when offline.
final class RawGPTService {

    static let shared = RawGPTService()
    private init() {}

    private let endpoint = "https://mealmind.japaneast.cloudapp.azure.com:5030/api/rawGPT"

    // MARK: - Request / Response

    private struct GPTRequest: Encodable {
        let message_text: String
    }

    // The rawGPT endpoint returns varying JSON shapes. Extract the best text available.
    private func extractText(from data: Data) throws -> String {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        // Top-level string fields in priority order
        let topLevel = ["response", "overall_summary", "回答", "answer", "Summary", "message", "result"]
        for key in topLevel {
            if let text = json[key] as? String, !text.isEmpty { return text }
        }
        // Nested: analysis object may contain string values
        if let analysis = json["analysis"] as? [String: Any] {
            let parts = analysis.values.compactMap { $0 as? String }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        // Nested: recommendations
        if let recs = json["recommendations"] as? [String: Any] {
            let parts = recs.values.compactMap { v -> String? in
                if let s = v as? String { return s }
                if let arr = v as? [String] { return arr.joined(separator: "；") }
                return nil
            }
            if !parts.isEmpty { return parts.joined(separator: "\n") }
        }
        throw URLError(.cannotParseResponse)
    }

    // MARK: - Public API

    /// Sends `prompt` to rawGPT and returns the Summary text.
    /// Throws on network error or decoding failure.
    func ask(_ prompt: String) async throws -> String {
        guard let url = URL(string: endpoint) else { throw URLError(.badURL) }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(GPTRequest(message_text: prompt))

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        return try extractText(from: data)
    }
}
