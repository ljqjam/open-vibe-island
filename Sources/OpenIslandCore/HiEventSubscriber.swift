import Foundation
import os

/// Maintains an outbound WebSocket connection to the Hi 开放平台 event-subscription
/// endpoint and delivers the plain text of incoming single-chat messages.
///
/// This is the "read side" companion to `HiNotificationRelay` (the "write side").
/// Because Open Island is a local, server-less app, Hi cannot call into this machine;
/// instead we keep an outbound WebSocket so the user's replies (typed text or the text
/// emitted by a card `sendMessage` button) flow back here in real time.
///
/// Mirrors `HiNotificationRelay`'s concurrency model: `@unchecked Sendable` with a
/// serial `DispatchQueue` guarding mutable state, and all failures swallowed/logged so
/// the rest of the app keeps working (fail-open).
///
/// Protocol (see Hi doc 事件订阅 WebSocket 接收消息):
/// - Connect to `wss://<host>/event/ws/endpoint?appId=..&appSecret=..`
/// - Server sends `{"type":"CONNECTED"}` on success.
/// - Client must send `{"type":"PING"}` every ~5s (30s timeout).
/// - On each event the client must reply `{"type":"ACK_EVENT","eventType":..,"eventId":..}`
///   within 3s; events are delivered in order, one at a time.
public final class HiEventSubscriber: @unchecked Sendable {
    private static let logger = Logger(subsystem: "app.openisland", category: "HiEventSubscriber")

    /// Event type for single-chat messages and group @-mentions.
    private static let chatMessageEventType = "asn:bot.chat.message:v1"

    private static let heartbeatInterval: TimeInterval = 5
    private static let maxReconnectDelay: TimeInterval = 30

    public struct Config: Sendable {
        public var appId: String
        public var appSecret: String
        public var baseURL: String

        public init(
            appId: String,
            appSecret: String,
            baseURL: String = "https://redcity-open.xiaohongshu.com"
        ) {
            self.appId = appId
            self.appSecret = appSecret
            self.baseURL = baseURL
        }
    }

    /// Called with the plain text of each incoming single-chat message. May be invoked
    /// on an arbitrary background thread; consumers should hop to their own executor.
    public var onReply: ((String) -> Void)?

    private let config: Config
    private let session: URLSession

    // All mutable state guarded by `queue`.
    private let queue = DispatchQueue(label: "app.openisland.hi.subscriber")
    private var task: URLSessionWebSocketTask?
    private var heartbeatTask: Task<Void, Never>?
    private var isStopped = false
    private var reconnectAttempts = 0

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - Lifecycle

    public func start() {
        queue.sync {
            guard !isStopped, task == nil else { return }
            connectLocked()
        }
    }

    public func stop() {
        queue.sync {
            isStopped = true
            heartbeatTask?.cancel()
            heartbeatTask = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
        }
    }

    // MARK: - Connection

    /// Must be called on `queue`.
    private func connectLocked() {
        guard let url = websocketURL(config: config) else {
            Self.logger.error("Hi WebSocket URL construction failed")
            return
        }

        let newTask = session.webSocketTask(with: url)
        task = newTask
        newTask.resume()
        Self.logger.info("Hi WebSocket connecting…")

        startHeartbeatLocked()
        receiveNext(on: newTask)
    }

    private func startHeartbeatLocked() {
        heartbeatTask?.cancel()
        heartbeatTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                if Task.isCancelled { return }
                let current = self.queue.sync { self.task }
                guard let current else { return }
                current.send(.string("{\"type\":\"PING\"}")) { error in
                    if let error {
                        Self.logger.debug("Hi WebSocket ping failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
    }

    /// Recursively reads the next message on the given task.
    private func receiveNext(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(message):
                self.handle(message: message, on: task)
                // Continue reading only if this is still the active task.
                if self.queue.sync(execute: { self.task === task && !self.isStopped }) {
                    self.receiveNext(on: task)
                }
            case let .failure(error):
                Self.logger.info("Hi WebSocket closed: \(error.localizedDescription, privacy: .public)")
                self.scheduleReconnect(after: task)
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message, on task: URLSessionWebSocketTask) {
        let text: String
        switch message {
        case let .string(value):
            text = value
        case let .data(value):
            text = String(data: value, encoding: .utf8) ?? ""
        @unknown default:
            return
        }
        guard !text.isEmpty else { return }

        // Reset backoff on any successful frame.
        queue.sync { reconnectAttempts = 0 }

        guard let outer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            return
        }

        // Control frames: CONNECTED / PONG have a `type` and no `eventType`.
        if let type = outer["type"] as? String, outer["eventType"] == nil {
            if type == "CONNECTED" {
                Self.logger.info("Hi WebSocket connected")
            }
            return
        }

        guard let eventType = outer["eventType"] as? String else { return }
        let eventId = outer["eventId"] as? String

        // ACK first so the server keeps delivering (3s window).
        sendAck(eventType: eventType, eventId: eventId, on: task)

        guard eventType == Self.chatMessageEventType else { return }

        // The event payload arrives either as a nested object (`payload`) or, per some
        // docs, as a JSON string (`payloadJson`). Support both.
        let payload: [String: Any]?
        if let object = outer["payload"] as? [String: Any] {
            payload = object
        } else if let json = outer["payloadJson"] as? String,
                  let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] {
            payload = object
        } else {
            payload = nil
        }

        guard let payload,
              !Self.isFromBot(payload),
              let replyText = Self.extractText(fromPayload: payload) else {
            return
        }

        Self.logger.info("Hi WebSocket reply received: \(replyText, privacy: .public)")
        onReply?(replyText)
    }

    private func sendAck(eventType: String, eventId: String?, on task: URLSessionWebSocketTask) {
        var ack: [String: Any] = ["type": "ACK_EVENT", "eventType": eventType]
        if let eventId { ack["eventId"] = eventId }
        guard let data = try? JSONSerialization.data(withJSONObject: ack),
              let string = String(data: data, encoding: .utf8) else {
            return
        }
        task.send(.string(string)) { error in
            if let error {
                Self.logger.debug("Hi WebSocket ACK failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// True when the message was authored by the application robot itself (avoid echoes).
    private static func isFromBot(_ payload: [String: Any]) -> Bool {
        guard let imMessage = payload["imMessage"] as? [String: Any],
              let creator = imMessage["creatorContactId"] as? String,
              let asn = payload["asn"] as? [String: Any],
              let asnAccount = asn["accountId"] as? String else {
            return false
        }
        return creator == asnAccount
    }

    /// Extracts the reply text from a chat-message event payload. Supports both the
    /// `{"plainText":{"text":..}}` shape (observed) and the flat `{"text":..}` shape (docs).
    private static func extractText(fromPayload payload: [String: Any]) -> String? {
        guard let imMessage = payload["imMessage"] as? [String: Any],
              let dataString = imMessage["data"] as? String,
              let inner = try? JSONSerialization.jsonObject(with: Data(dataString.utf8)) as? [String: Any] else {
            return nil
        }
        if let plain = inner["plainText"] as? [String: Any], let text = plain["text"] as? String {
            return text
        }
        if let text = inner["text"] as? String {
            return text
        }
        return nil
    }

    private func scheduleReconnect(after closedTask: URLSessionWebSocketTask) {
        let delay: TimeInterval? = queue.sync { () -> TimeInterval? in
            guard !isStopped, task === closedTask else { return nil }
            task = nil
            heartbeatTask?.cancel()
            heartbeatTask = nil
            reconnectAttempts += 1
            let backoff = min(Self.maxReconnectDelay, pow(2, Double(min(reconnectAttempts, 4))))
            return backoff
        }
        guard let delay else { return }
        Self.logger.info("Hi WebSocket reconnecting in \(delay, privacy: .public)s")
        Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self else { return }
            self.queue.sync {
                guard !self.isStopped, self.task == nil else { return }
                self.connectLocked()
            }
        }
    }

    private func websocketURL(config: Config) -> URL? {
        guard var components = URLComponents(string: config.baseURL) else { return nil }
        components.scheme = (components.scheme == "http") ? "ws" : "wss"
        components.path = "/event/ws/endpoint"
        components.queryItems = [
            URLQueryItem(name: "appId", value: config.appId),
            URLQueryItem(name: "appSecret", value: config.appSecret),
        ]
        return components.url
    }
}
