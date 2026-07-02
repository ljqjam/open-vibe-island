import Foundation
import Testing
@testable import OpenIslandCore

struct HiNotificationRelayTests {
    private func makeRelay() -> HiNotificationRelay {
        HiNotificationRelay(
            config: .init(
                appId: "app",
                appSecret: "secret",
                asnId: "asn",
                recipientAccountId: "user@xiaohongshu.com"
            )
        )
    }

    // MARK: - interpretDecision

    @Test
    func interpretsApproval() {
        for token in ["y", "Y", "yes", "1", "同意", "批准", "允许", "approve", "allow", "y a3f9"] {
            #expect(HiNotificationRelay.interpretDecision(token) == true, "\(token) should approve")
        }
    }

    @Test
    func interpretsDenial() {
        for token in ["n", "no", "2", "拒绝", "deny", "reject", "n a3f9"] {
            #expect(HiNotificationRelay.interpretDecision(token) == false, "\(token) should deny")
        }
    }

    @Test
    func interpretsUnknownAsNil() {
        for token in ["", "maybe", "hello", "3", "a3f9"] {
            #expect(HiNotificationRelay.interpretDecision(token) == nil, "\(token) should be nil")
        }
    }

    // MARK: - extractCode

    @Test
    func extractsFourCharCode() {
        #expect(HiNotificationRelay.extractCode("y a3f9") == "a3f9")
        #expect(HiNotificationRelay.extractCode("approve CODE1234") == nil) // only 4-char tokens
        #expect(HiNotificationRelay.extractCode("n") == nil)
        #expect(HiNotificationRelay.extractCode("拒绝 1a2b") == "1a2b")
    }

    // MARK: - ingestReply

    @Test
    func ingestReplyResolvesSinglePendingWithoutCode() async {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "a3f9", sessionID: "sess-1")

        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<(String, Bool), Never>) in
            relay.onResolve = { sessionID, approved in
                continuation.resume(returning: (sessionID, approved))
            }
            relay.ingestReply("y")
        }
        #expect(resolved.0 == "sess-1")
        #expect(resolved.1 == true)
    }

    @Test
    func ingestReplyMatchesByCodeWhenMultiplePending() async {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "aaaa", sessionID: "sess-a")
        relay.registerPendingApproval(code: "bbbb", sessionID: "sess-b")

        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<(String, Bool), Never>) in
            relay.onResolve = { sessionID, approved in
                continuation.resume(returning: (sessionID, approved))
            }
            relay.ingestReply("n bbbb")
        }
        #expect(resolved.0 == "sess-b")
        #expect(resolved.1 == false)
    }

    @Test
    func ingestReplyIgnoresAmbiguousMultiplePending() {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "aaaa", sessionID: "sess-a")
        relay.registerPendingApproval(code: "bbbb", sessionID: "sess-b")

        var called = false
        relay.onResolve = { _, _ in called = true }
        relay.ingestReply("y") // no code, multiple pending -> ignore
        #expect(called == false)
    }

    @Test
    func ingestReplyIgnoresUninterpretableText() {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "a3f9", sessionID: "sess-1")

        var called = false
        relay.onResolve = { _, _ in called = true }
        relay.ingestReply("what is happening")
        #expect(called == false)
    }

    @Test
    func forgetApprovalRemovesPending() {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "a3f9", sessionID: "sess-1")
        relay.forgetApproval(sessionID: "sess-1")

        var called = false
        relay.onResolve = { _, _ in called = true }
        relay.ingestReply("y")
        #expect(called == false)
    }

    // MARK: - ingestReply sender routing (shared robot / multi-user)

    @Test
    func ingestReplyIgnoresReplyFromDifferentSender() {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "a3f9", sessionID: "sess-1", recipient: "alice@xiaohongshu.com")

        var called = false
        relay.onResolve = { _, _ in called = true }
        // Bob replies to a request addressed to Alice -> must be ignored.
        relay.ingestReply("y", from: "bob@xiaohongshu.com")
        #expect(called == false)
    }

    @Test
    func ingestReplyResolvesWhenSenderMatchesRecipient() async {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "a3f9", sessionID: "sess-1", recipient: "alice@xiaohongshu.com")

        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<(String, Bool), Never>) in
            relay.onResolve = { sessionID, approved in
                continuation.resume(returning: (sessionID, approved))
            }
            relay.ingestReply("y", from: "alice@xiaohongshu.com")
        }
        #expect(resolved.0 == "sess-1")
        #expect(resolved.1 == true)
    }

    @Test
    func ingestReplyByCodeIgnoredWhenSenderMismatch() {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "aaaa", sessionID: "sess-a", recipient: "alice@xiaohongshu.com")
        relay.registerPendingApproval(code: "bbbb", sessionID: "sess-b", recipient: "bob@xiaohongshu.com")

        var called = false
        relay.onResolve = { _, _ in called = true }
        // Alice tries to resolve Bob's code -> ignored (sender mismatch on that code).
        relay.ingestReply("y bbbb", from: "alice@xiaohongshu.com")
        #expect(called == false)
    }

    @Test
    func ingestReplyResolvesPerSenderSinglePendingAmongMany() async {
        let relay = makeRelay()
        relay.registerPendingApproval(code: "aaaa", sessionID: "sess-a", recipient: "alice@xiaohongshu.com")
        relay.registerPendingApproval(code: "bbbb", sessionID: "sess-b", recipient: "bob@xiaohongshu.com")

        // Alice has exactly one pending for her; a bare "y" should resolve only hers.
        let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<(String, Bool), Never>) in
            relay.onResolve = { sessionID, approved in
                continuation.resume(returning: (sessionID, approved))
            }
            relay.ingestReply("y", from: "alice@xiaohongshu.com")
        }
        #expect(resolved.0 == "sess-a")
        #expect(resolved.1 == true)
    }
}
