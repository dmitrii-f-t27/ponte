import Foundation
import PonteCore

/// Apple (on device) and optional Claude behind one `Translator`, with the choice, per-attempt
/// timeout, retry and fallback decided by `SpeechRules`.
public final class RoutingTranslator: Translator, @unchecked Sendable {
    /// Try Claude first when it is available (`SpeechRules.primaryEngine`).
    public var preferClaude: Bool
    /// The engine that produced the last translation: `SpeechRules.engineApple` / `engineClaude`.
    public var lastEngine: Int { lock.withLock { _lastEngine } }

    public var name: String {
        let parts = [apple?.name, claude?.name].compactMap { $0 }
        return parts.isEmpty ? "нет переводчика" : parts.joined(separator: " + ")
    }

    private let apple: Translator?
    private let claude: Translator?
    private let lock = NSLock()
    private var appleReady: Set<String> = []
    private var _lastEngine = SpeechRules.engineNone

    /// - Parameters:
    ///   - apple: on-device translator (`AppleTranslator()`), nil to disable.
    ///   - claude: cloud translator (`ClaudeTranslator()`, nil when there is no key).
    public init(apple: Translator? = AppleTranslator(), claude: Translator? = ClaudeTranslator(), preferClaude: Bool = false) {
        self.apple = apple
        self.claude = claude
        self.preferClaude = preferClaude
    }

    private static func key(_ from: Lang, _ to: Lang) -> String { "\(from.rawValue)>\(to.rawValue)" }

    /// Succeeds when at least one engine can translate the pair. If none can, throws the Apple error
    /// (for example `translationAssetsMissing`, which the setup wizard turns into a download).
    public func prepare(from: Lang, to: Lang) async throws {
        var appleError: Error?
        if let apple {
            do {
                try await apple.prepare(from: from, to: to)
                _ = lock.withLock { appleReady.insert(Self.key(from, to)) }
            } catch {
                appleError = error
                _ = lock.withLock { appleReady.remove(Self.key(from, to)) }
            }
        }
        var claudeOK = false
        if let claude {
            do {
                try await claude.prepare(from: from, to: to)
                claudeOK = true
            } catch {
                if SpeechRules.rethrowsClaudeError(appleFailed: appleError != nil, hasApple: apple != nil) { throw error }
            }
        }
        let engine = SpeechRules.primaryEngine(preferred: preferred, appleReady: isAppleReady(from, to),
                                               claudeAvailable: claudeOK)
        if engine == SpeechRules.engineNone {
            throw appleError ?? PonteSpeechError.translationUnsupported(from: from, to: to)
        }
    }

    private var preferred: Int { SpeechRules.preferredEngine(preferClaude: preferClaude) }

    private func isAppleReady(_ from: Lang, _ to: Lang) -> Bool {
        apple != nil && lock.withLock { appleReady.contains(Self.key(from, to)) }
    }

    public func translate(_ text: String, from: Lang, to: Lang, context: [String]) async throws -> String {
        let claudeAvailable = claude != nil
        var engine = SpeechRules.primaryEngine(preferred: preferred, appleReady: isAppleReady(from, to),
                                               claudeAvailable: claudeAvailable)
        var attempt = 0
        while true {
            guard let translator = translator(for: engine) else {
                throw PonteSpeechError.translationAssetsMissing(from: from, to: to)
            }
            do {
                let result = try await Self.withTimeout(ms: SpeechRules.translationTimeoutMs(engine: engine), name: translator.name) {
                    try await translator.translate(text, from: from, to: to, context: context)
                }
                if SpeechRules.emptyTranslation(resultEmpty: result.isEmpty,
                                                inputEmpty: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    throw PonteSpeechError.cloudEmptyResponse
                }
                lock.withLock { _lastEngine = engine }
                return result
            } catch {
                let code = Self.errorCode(error)
                if SpeechRules.forgetsAppleReady(engine: engine, errorCode: code) {
                    _ = lock.withLock { appleReady.remove(Self.key(from, to)) }
                }
                let fallback = SpeechRules.fallbackEngine(failed: engine, appleReady: isAppleReady(from, to),
                                                          claudeAvailable: claudeAvailable)
                switch SpeechRules.retryAction(errorCode: code, attempt: attempt, fallback: fallback) {
                case SpeechRules.retrySame: break
                case SpeechRules.retrySwitch: engine = fallback
                default: throw error
                }
                attempt += 1
            }
        }
    }

    private func translator(for engine: Int) -> Translator? {
        switch engine {
        case SpeechRules.engineApple: return apple
        case SpeechRules.engineClaude: return claude
        default: return nil
        }
    }

    /// Maps an error to a `SpeechRules` error code: the Swift error type gives the kind, the rule the code.
    static func errorCode(_ error: Error) -> Int {
        let (kind, status) = errorKind(error)
        return SpeechRules.errorCode(kind: kind, httpStatus: status)
    }

    static func errorKind(_ error: Error) -> (kind: Int, httpStatus: Int) {
        guard let e = error as? PonteSpeechError else {
            return ((error as? URLError) != nil ? SpeechRules.kindURL : SpeechRules.kindOther, 0)
        }
        switch e {
        case .translationTimedOut: return (SpeechRules.kindTimeout, 0)
        case .translationAssetsMissing: return (SpeechRules.kindAssetsMissing, 0)
        case .translationUnsupported: return (SpeechRules.kindUnsupported, 0)
        case .cloudRequestFailed(let status, _): return (SpeechRules.kindCloudRequest, status)
        case .cloudKeyMissing: return (SpeechRules.kindKeyMissing, 0)
        case .cloudRefused: return (SpeechRules.kindRefused, 0)
        case .cloudEmptyResponse: return (SpeechRules.kindEmpty, 0)
        default: return (SpeechRules.kindOther, 0)
        }
    }

    static func withTimeout<T: Sendable>(ms: Int, name: String, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard SpeechRules.hasTimeout(ms: ms) else { return try await work() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: .milliseconds(ms))
                throw PonteSpeechError.translationTimedOut(name, ms: ms)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw PonteSpeechError.translationTimedOut(name, ms: ms) }
            return first
        }
    }
}
