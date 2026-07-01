import Foundation
import os

/// Relays selected AppModel events to Hi IM via the Hi 开放平台 OpenAPI (personal push).
///
/// Mirrors `WatchNotificationRelay`: it receives `notifyEvent(_:session:)` from the
/// (MainActor) event pipeline, extracts value-type data synchronously, then fires a
/// detached network task. All failures are swallowed and logged so the agent/notch
/// pipeline keeps working even when Hi is misconfigured or unreachable (fail-open).
public final class HiNotificationRelay: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.openisland", category: "HiNotificationRelay")

    /// API alias for "应用号发送消息到个人 (V2)" — only requires an AppAccessToken.
    private static let sendMessageAlias = "redcity:asn.asnSendMessageToPerson:v2"

    /// Refresh the AppAccessToken when fewer than this many seconds remain.
    private static let tokenRefreshLeadTime: TimeInterval = 30 * 60

    /// Message types accepted by the Hi API.
    private enum MessageType: Int {
        case text = 1
        case markdown = 2
        case card = 13
    }

    public struct Config: Sendable {
        public var appId: String
        public var appSecret: String
        public var asnId: String
        public var recipientAccountId: String
        /// Optional card template ID (schemaId). When empty, permission requests are
        /// sent as plain text instead of a card.
        public var cardSchemaId: String
        public var baseURL: String

        public init(
            appId: String,
            appSecret: String,
            asnId: String,
            recipientAccountId: String,
            cardSchemaId: String = "",
            baseURL: String = "https://redcity-open.xiaohongshu.com"
        ) {
            self.appId = appId
            self.appSecret = appSecret
            self.asnId = asnId
            self.recipientAccountId = recipientAccountId
            self.cardSchemaId = cardSchemaId
            self.baseURL = baseURL
        }
    }

    /// A permission request that was pushed to Hi and is awaiting the user's reply.
    private struct PendingApproval {
        var sessionID: String
        var createdAt: Date
    }

    /// Invoked when an incoming Hi reply resolves a pending permission request.
    /// Called on an arbitrary background thread; consumers should hop to their executor.
    public var onResolve: ((_ sessionID: String, _ approved: Bool) -> Void)?

    private let config: Config
    private let session: URLSession

    // Token cache — guarded by `queue`.
    private let queue = DispatchQueue(label: "app.openisland.hi.relay")
    private var cachedToken: String?
    private var tokenExpiresAt: Date = .distantPast
    private var isStopped = false

    // Permission requests awaiting a Hi reply, keyed by a short code — guarded by `queue`.
    private var pendingApprovals: [String: PendingApproval] = [:]

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Lifecycle

    /// No-op; exists for lifecycle symmetry with `WatchNotificationRelay`.
    public func start() {}

    /// Marks the relay stopped so any subsequent pushes short-circuit.
    public func stop() {
        queue.sync { isStopped = true }
    }

    // MARK: - Event Notification

    /// Called by AppModel after applying a tracked event. Filters for the three
    /// actionable event types. Permission requests are pushed as an interactive card
    /// (with a plain-text fallback) that the user can approve/deny by replying in Hi;
    /// questions and completions are pushed as plain text notifications.
    public func notifyEvent(_ event: AgentEvent, session: AgentSession?) {
        guard let session else { return }
        let tool = session.tool.displayName
        let workingDirectory = session.jumpTarget?.workingDirectory

        switch event {
        case let .permissionRequested(payload):
            let request = payload.request
            let sessionID = payload.sessionID
            let code = Self.makeCode()
            queue.sync {
                pendingApprovals[code] = PendingApproval(sessionID: sessionID, createdAt: .now)
            }

            var detailLines: [String] = []
            if !request.summary.isEmpty { detailLines.append(request.summary) }
            if let workingDirectory, !workingDirectory.isEmpty {
                detailLines.append("目录: \(workingDirectory)")
            }
            let detail = detailLines.joined(separator: "\n")

            let config = self.config
            Task.detached(priority: .utility) { [weak self] in
                await self?.pushPermission(
                    tool: tool,
                    title: request.title,
                    detail: detail,
                    code: code,
                    config: config
                )
            }

        case let .questionAsked(payload):
            let prompt = payload.prompt
            var lines = ["[\(tool)] 提问", prompt.title]
            if !prompt.options.isEmpty {
                lines.append("选项:")
                lines.append(contentsOf: prompt.options.map { "- \($0)" })
            }
            pushText(lines.joined(separator: "\n"), abbrev: "\(tool) 提问: \(prompt.title)")

        case let .sessionCompleted(payload):
            var lines = ["[\(tool)] 任务完成"]
            if !payload.summary.isEmpty { lines.append(payload.summary) }
            if let workingDirectory, !workingDirectory.isEmpty {
                lines.append("目录: \(workingDirectory)")
            }
            pushText(lines.joined(separator: "\n"), abbrev: "\(tool) 任务完成")

        default:
            break
        }
    }

    private func pushText(_ text: String, abbrev: String) {
        let config = self.config
        Task.detached(priority: .utility) { [weak self] in
            await self?.push(text: text, abbrev: abbrev, config: config)
        }
    }

    // MARK: - Incoming Replies

    /// Handles a plain-text reply received from Hi (typed by the user or emitted by a
    /// card `sendMessage` button). Resolves a matching pending permission request and
    /// invokes `onResolve`. No-op when the reply cannot be interpreted or matched.
    public func ingestReply(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let approved = Self.interpretDecision(trimmed) else { return }

        let code = Self.extractCode(trimmed)
        let resolved: String? = queue.sync {
            if let code, let pending = pendingApprovals[code] {
                pendingApprovals.removeValue(forKey: code)
                return pending.sessionID
            }
            // No explicit code: only act when exactly one request is pending, to avoid
            // resolving the wrong one.
            guard pendingApprovals.count == 1, let entry = pendingApprovals.first else {
                return nil
            }
            pendingApprovals.removeValue(forKey: entry.key)
            return entry.value.sessionID
        }

        guard let sessionID = resolved else {
            Self.logger.info("Hi reply '\(trimmed, privacy: .public)' matched no pending approval")
            return
        }
        Self.logger.info("Hi reply resolving session \(sessionID, privacy: .public) approved=\(approved, privacy: .public)")
        onResolve?(sessionID, approved)
    }

    /// Removes a pending approval once it has been resolved elsewhere (notch/terminal),
    /// so a late Hi reply doesn't act on a stale request.
    public func forgetApproval(sessionID: String) {
        queue.sync {
            pendingApprovals = pendingApprovals.filter { $0.value.sessionID != sessionID }
        }
    }

    private static func makeCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(4)).lowercased()
    }

    /// Registers a pending approval directly. Test seam for `ingestReply`.
    func registerPendingApproval(code: String, sessionID: String) {
        queue.sync {
            pendingApprovals[code] = PendingApproval(sessionID: sessionID, createdAt: .now)
        }
    }

    static func extractCode(_ text: String) -> String? {
        // A 4-char alphanumeric token anywhere in the reply.
        let tokens = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        return tokens.first { $0.count == 4 && $0.allSatisfy { $0.isLetter || $0.isNumber } }
            .map(String.init)
    }

    /// Interprets an approval/denial intent from free-form text. Returns nil when the
    /// text carries no recognizable decision.
    static func interpretDecision(_ text: String) -> Bool? {
        let lower = text.lowercased()
        let approve = ["y", "yes", "1", "同意", "批准", "允许", "approve", "allow"]
        let deny = ["n", "no", "2", "拒绝", "不", "deny", "reject"]
        // Word-ish match: check tokens so "y a3f9" and bare "y" both work.
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber && !("\u{4e00}"..."\u{9fff}").contains($0) }.map(String.init))
        if tokens.contains(where: { approve.contains($0) }) { return true }
        if tokens.contains(where: { deny.contains($0) }) { return false }
        return nil
    }

    // MARK: - Test

    /// Sends a test message using the current config. Unlike the event push path,
    /// this throws on failure so callers (e.g. a Settings button) can surface the result.
    public func sendTestMessage() async throws {
        let text = [
            "[Open Island] 测试消息",
            "Hi 推送配置成功 ✅",
        ].joined(separator: "\n")
        try await send(text: text, abbrev: "Open Island 测试消息", config: config)
    }

    // MARK: - Networking

    private func push(text: String, abbrev: String, config: Config) async {
        do {
            try await send(text: text, abbrev: abbrev, config: config)
        } catch {
            Self.logger.error("Hi push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends a permission request: an interactive card when a template is configured,
    /// falling back to plain text (which still carries the reply instructions) on any
    /// card failure or when no template is set.
    private func pushPermission(
        tool: String,
        title: String,
        detail: String,
        code: String,
        config: Config
    ) async {
        let abbrev = "\(tool) 权限请求: \(title)"
        var textLines = ["[\(tool)] 权限请求", title]
        if !detail.isEmpty { textLines.append(detail) }
        textLines.append("回复 y 批准 / n 拒绝（多条待审批时回复: y \(code)）")
        let fallbackText = textLines.joined(separator: "\n")

        if !config.cardSchemaId.isEmpty {
            do {
                try await sendCard(
                    tool: tool,
                    title: title,
                    detail: detail,
                    code: code,
                    abbrev: abbrev,
                    config: config
                )
                return
            } catch {
                Self.logger.error("Hi card push failed, falling back to text: \(error.localizedDescription, privacy: .public)")
            }
        }

        await push(text: fallbackText, abbrev: abbrev, config: config)
    }

    private func send(text: String, abbrev: String, config: Config) async throws {
        try await sendRaw(
            messageType: .text,
            messageContent: text,
            abbrev: abbrev,
            config: config
        )
    }

    /// Builds and sends a static card message (messageType=13). The card renders
    /// `title`/`content`/`code` via template variables and its `sendMessage` buttons
    /// emit `y`/`n` so the reply flows back through the WebSocket subscriber.
    private func sendCard(
        tool: String,
        title: String,
        detail: String,
        code: String,
        abbrev: String,
        config: Config
    ) async throws {
        let entityData: [String: Any] = [
            "tool": tool,
            "title": title,
            "content": detail,
            "code": code,
        ]
        guard let entityDataData = try? JSONSerialization.data(withJSONObject: entityData),
              let entityDataString = String(data: entityDataData, encoding: .utf8) else {
            throw HiRelayError.invalidRequest
        }

        let cardContent: [String: Any] = [
            "entitySchemaId": config.cardSchemaId,
            "type": 1,
            "dataSourceType": 1,
            "subject": title,
            "entityData": entityDataString,
        ]
        guard let cardData = try? JSONSerialization.data(withJSONObject: cardContent),
              let cardString = String(data: cardData, encoding: .utf8) else {
            throw HiRelayError.invalidRequest
        }

        try await sendRaw(
            messageType: .card,
            messageContent: cardString,
            abbrev: abbrev,
            config: config
        )
    }

    private func sendRaw(
        messageType: MessageType,
        messageContent: String,
        abbrev: String,
        config: Config
    ) async throws {
        if queue.sync(execute: { isStopped }) { return }

        let token = try await fetchOrRefreshToken(config: config)

        let bizParams: [String: Any] = [
            "asnId": config.asnId,
            "accountList": [config.recipientAccountId],
            "messageType": messageType.rawValue,
            "messageContent": messageContent,
            "messageAbbrevContent": abbrev,
            "businessId": UUID().uuidString,
            "messageSource": 1,
        ]

        guard let bizParamsData = try? JSONSerialization.data(withJSONObject: bizParams),
              let bizParamsString = String(data: bizParamsData, encoding: .utf8) else {
            throw HiRelayError.invalidRequest
        }

        let body: [String: Any] = [
            "appId": config.appId,
            "appAccessToken": token,
            "apiAlias": Self.sendMessageAlias,
            "bizParams": bizParamsString,
        ]

        guard let request = makeRequest(
            path: "/openapis/open/api/call/v2",
            body: body,
            config: config
        ) else {
            throw HiRelayError.invalidRequest
        }

        let (data, _) = try await session.data(for: request)
        // The gateway wraps the real business result as a JSON *string* in `data`.
        // The outer `success` only reflects transport-level success, so the actual
        // send result must be parsed from the nested payload.
        guard let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HiRelayError.invalidResponse
        }
        if let outerSuccess = outer["success"] as? Bool, outerSuccess == false {
            let msg = (outer["errorMsg"] as? String) ?? (outer["bizErrorMessage"] as? String) ?? "gateway error"
            throw HiRelayError.server(msg)
        }
        guard let innerString = outer["data"] as? String,
              let innerData = innerString.data(using: .utf8),
              let inner = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any] else {
            throw HiRelayError.invalidResponse
        }
        guard (inner["success"] as? Bool) == true else {
            let msg = (inner["msg"] as? String) ?? "send failed"
            let code = inner["code"].map { "\($0)" } ?? ""
            throw HiRelayError.server(code.isEmpty ? msg : "\(msg) (code \(code))")
        }
    }

    /// Returns a cached AppAccessToken when still valid, otherwise fetches a new one.
    /// Runs inside a detached Task (never on MainActor) so `queue.sync` is deadlock-free.
    private func fetchOrRefreshToken(config: Config) async throws -> String {
        if let cached = queue.sync(execute: { () -> String? in
            guard let cachedToken, tokenExpiresAt.timeIntervalSinceNow > Self.tokenRefreshLeadTime else {
                return nil
            }
            return cachedToken
        }) {
            return cached
        }

        guard let request = makeRequest(
            path: "/openapis/open/token/createAppAccessToken/v2",
            body: ["appId": config.appId, "appSecret": config.appSecret],
            config: config
        ) else {
            throw HiRelayError.invalidRequest
        }

        let (data, _) = try await session.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HiRelayError.invalidResponse
        }
        guard (json["success"] as? Bool) == true,
              let token = json["appAccessToken"] as? String else {
            let msg = (json["errorMsg"] as? String) ?? "token request failed"
            throw HiRelayError.server(msg)
        }

        let expiresIn = (json["expiresIn"] as? Double) ?? (json["expiresIn"] as? Int).map(Double.init) ?? 7199
        let expiresAt = Date().addingTimeInterval(expiresIn)
        queue.sync {
            cachedToken = token
            tokenExpiresAt = expiresAt
        }
        return token
    }

    private func makeRequest(path: String, body: [String: Any], config: Config) -> URLRequest? {
        guard let url = URL(string: config.baseURL + path),
              let data = try? JSONSerialization.data(withJSONObject: body) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return request
    }

    private enum HiRelayError: LocalizedError {
        case invalidRequest
        case invalidResponse
        case server(String)

        var errorDescription: String? {
            switch self {
            case .invalidRequest: return "请求构造失败"
            case .invalidResponse: return "响应解析失败"
            case let .server(msg): return msg
            }
        }
    }
}
