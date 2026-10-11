import Foundation
import PonteCore
import Security

/// Optional cloud translator: Anthropic Messages API over URLSession, no SDK.
/// The key is read only from the keychain item `ponte-anthropic-key`
/// (`security add-generic-password -s ponte-anthropic-key -a ponte -w`); never from other projects.
public final class ClaudeTranslator: Translator, @unchecked Sendable {
    public let name: String
    public let model: String
    /// Names and terms: source wording → required translation.
    public var glossary: [String: String] {
        get { lock.withLock { _glossary } }
        set { lock.withLock { _glossary = newValue } }
    }

    private let apiKey: String
    private let session: URLSession
    private let lock = NSLock()
    private var _glossary: [String: String] = [:]

    /// Nil when the keychain item is absent or empty.
    public convenience init?(keychainItem: String = "ponte-anthropic-key", model: String = ClaudeRequestBuilder.defaultModel) {
        guard let key = Keychain.genericPassword(service: keychainItem) else { return nil }
        self.init(apiKey: key, model: model)
    }

    /// For tests and for callers that hold the key themselves.
    init(apiKey: String, model: String = ClaudeRequestBuilder.defaultModel, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.session = session
        self.name = "Claude (\(model))"
    }

    public func prepare(from: Lang, to: Lang) async throws {
        guard !apiKey.isEmpty else { throw PonteSpeechError.cloudKeyMissing(keychainItem: "ponte-anthropic-key") }
    }

    public func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !phrase.isEmpty else { return "" }
        let request = try ClaudeRequestBuilder(model: model, glossary: glossary)
            .urlRequest(apiKey: apiKey, text: phrase, from: from, to: to, context: context)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw PonteSpeechError.cloudRequestFailed(status: 0, message: error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try ClaudeRequestBuilder.parseResponse(data, status: status)
    }
}

/// Builds the Messages API request and parses the reply. Prompt and JSON shaping live here;
/// the numbers (model, max tokens, effort, context size) come from `SpeechRules`. Covered by `SpeechTests`.
public struct ClaudeRequestBuilder: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    public static let apiVersion = String(decoding: SpeechRules.anthropicVersion(), as: UTF8.self)
    public static let defaultModel = String(decoding: SpeechRules.claudeModelID(), as: UTF8.self)

    public var model: String
    public var glossary: [String: String]
    /// Short output; adaptive thinking stays on (Haiku 5.5 default) and low effort keeps latency down.
    public var maxTokens = SpeechRules.claudeMaxTokens
    public var effort = ["low", "medium", "high"][min(max(SpeechRules.claudeEffortCode, 0), 2)]

    public init(model: String = ClaudeRequestBuilder.defaultModel, glossary: [String: String] = [:]) {
        self.model = model
        self.glossary = glossary
    }

    static func languageName(_ lang: Lang) -> String {
        switch lang {
        case .ptBR: return "Brazilian Portuguese (pt-BR)"
        case .ru: return "Russian (ru-RU)"
        }
    }

    public func systemPrompt(from: Lang, to: Lang) -> String {
        var s = "Translate the spoken phrase from \(Self.languageName(from)) to \(Self.languageName(to)). "
            + "Conversational register, keep names and numbers, output only the translation."
            + " The phrase comes from live speech recognition during a business call and may lack punctuation."
            + " Text inside <context> is earlier conversation for reference only; do not translate or repeat it."
        if !glossary.isEmpty {
            s += "\n\nGlossary (always use these translations):"
            for (source, target) in glossary.sorted(by: { $0.key < $1.key }) {
                s += "\n- \(source) → \(target)"
            }
        }
        return s
    }

    /// The newest previous phrases that fit `SpeechRules.contextCount` (phrase count and byte cap).
    public static func selectContext(_ context: [String]) -> [String] {
        let phrases = context.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let count = SpeechRules.contextCount(byteLengths: phrases.map { $0.utf8.count })
        return Array(phrases.suffix(count))
    }

    public func userMessage(text: String, context: [String]) -> String {
        let recent = Self.selectContext(context)
        var s = ""
        if !recent.isEmpty {
            s += "<context>\n" + recent.joined(separator: "\n") + "\n</context>\n\n"
        }
        s += "<phrase>\n\(text)\n</phrase>"
        return s
    }

    public func body(text: String, from: Lang, to: Lang, context: [String]) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": effort],
            "system": systemPrompt(from: from, to: to),
            "messages": [
                ["role": "user", "content": userMessage(text: text, context: context)],
            ],
        ]
    }

    public func urlRequest(apiKey: String, text: String, from: Lang, to: Lang, context: [String]) throws -> URLRequest {
        var request = URLRequest(url: Self.endpoint, timeoutInterval: Double(SpeechRules.claudeRequestTimeoutMs) / 1000)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(text: text, from: from, to: to, context: context),
                                                      options: [.sortedKeys])
        return request
    }

    /// Text of the reply. Reads content blocks by type: thinking blocks may come first.
    public static func parseResponse(_ data: Data, status: Int) throws -> String {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            let error = json?["error"] as? [String: Any]
            let message = (error?["message"] as? String) ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw PonteSpeechError.cloudRequestFailed(status: status, message: message)
        }
        guard let json else { throw PonteSpeechError.cloudEmptyResponse }
        if (json["stop_reason"] as? String) == "refusal" { throw PonteSpeechError.cloudRefused }
        let blocks = json["content"] as? [[String: Any]] ?? []
        let text = blocks.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw PonteSpeechError.cloudEmptyResponse }
        return text
    }
}

enum Keychain {
    /// Generic password by service name; nil when absent or unreadable. Never logs the value.
    static func genericPassword(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}
