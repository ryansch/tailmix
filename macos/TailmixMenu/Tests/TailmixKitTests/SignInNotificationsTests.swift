import Foundation
import Testing
@testable import TailmixKit

@Suite struct SignInNotificationsTests {
    // Friday 2026-11-27 10:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_795_773_600)
    private let utc = TimeZone(identifier: "UTC")!
    private let posix = Locale(identifier: "en_US_POSIX")

    private func plan(_ profiles: [Profile], sent: Set<String> = []) -> (post: [SignInNotification], sent: Set<String>) {
        SignInNotifications.plan(profiles: profiles, sent: sent, now: now, locale: posix, timeZone: utc)
    }

    private func expired(_ id: String = "p1", _ name: String = "home") -> Profile {
        Profile(id: id, name: name, enabled: true, runtimeState: "needs-login",
                keyExpiry: now.addingTimeInterval(-3600), keyExpired: true)
    }

    private func running(_ id: String = "p1", _ name: String = "home", expiresIn: TimeInterval? = nil) -> Profile {
        Profile(id: id, name: name, enabled: true, runtimeState: "running",
                keyExpiry: expiresIn.map { now.addingTimeInterval($0) })
    }

    @Test func testExpiredPostsOnce() {
        let first = plan([expired()])
        #expect(first.post == [SignInNotification(
            key: "expired:p1", profileID: "p1", title: "Sign in to home",
            body: "tailmix needs you to sign in to this tailnet again.")])
        #expect(first.sent == ["expired:p1"])

        let second = plan([expired()], sent: first.sent)
        #expect(second.post.isEmpty)
        #expect(second.sent == ["expired:p1"])
    }

    @Test func testConditionEndingForgetsKeyAndNextEpisodePostsAgain() {
        let first = plan([expired()])
        let back = plan([running(expiresIn: 180 * 86400)], sent: first.sent)
        #expect(back.post.isEmpty)
        #expect(back.sent.isEmpty)

        let again = plan([expired()], sent: back.sent)
        #expect(again.post.map(\.key) == ["expired:p1"])
        #expect(again.sent == ["expired:p1"])
    }

    @Test func testLogoutDoesNotNotify() {
        let loggedOut = Profile(id: "p1", name: "home", enabled: true, runtimeState: "needs-login", keyExpired: false)
        let result = plan([loggedOut])
        #expect(result.post.isEmpty)
        #expect(result.sent.isEmpty)
    }

    @Test func testExpiringPostsWithWeekday() {
        // Expires Sunday 2026-11-29 10:00 UTC.
        let result = plan([running(expiresIn: 2 * 86400)])
        #expect(result.post == [SignInNotification(
            key: "expiring:p1", profileID: "p1", title: "home key expires Sun",
            body: "Sign in again before then to stay connected.")])
        #expect(result.sent == ["expiring:p1"])

        #expect(plan([running(expiresIn: 2 * 86400)], sent: result.sent).post.isEmpty)
    }

    @Test func testExpiringOutsideWindowDoesNotNotify() {
        let result = plan([running(expiresIn: 4 * 86400)], sent: ["expiring:p1"])
        #expect(result.post.isEmpty)
        #expect(result.sent.isEmpty)
    }

    @Test func testProfilesHaveIndependentKeys() {
        let first = plan([expired("p1", "home"), running("p2", "work")])
        #expect(first.post.map(\.key) == ["expired:p1"])

        let second = plan([expired("p1", "home"), expired("p2", "work")], sent: first.sent)
        #expect(second.post == [SignInNotification(
            key: "expired:p2", profileID: "p2", title: "Sign in to work",
            body: "tailmix needs you to sign in to this tailnet again.")])
        #expect(second.sent == ["expired:p1", "expired:p2"])

        let third = plan([running("p1", "home"), expired("p2", "work")], sent: second.sent)
        #expect(third.post.isEmpty)
        #expect(third.sent == ["expired:p2"])
    }

    private func profile(_ state: String, keyExpired: Bool = false, expiresIn: TimeInterval? = nil) -> Profile {
        Profile(id: "p1", name: "home", enabled: true, runtimeState: state,
                keyExpiry: expiresIn.map { now.addingTimeInterval($0) }, keyExpired: keyExpired)
    }

    @Test func testTransientStateKeepsExpiringKey() {
        var sent: Set<String> = []
        var posted: [String] = []
        for state in ["running", "starting", "error", "running"] {
            let result = plan([profile(state, expiresIn: 2 * 86400)], sent: sent)
            posted += result.post.map(\.key)
            sent = result.sent
        }
        #expect(posted == ["expiring:p1"])
        #expect(sent == ["expiring:p1"])
    }

    @Test func testTransientStateKeepsExpiredKey() {
        var sent: Set<String> = []
        var posted: [String] = []
        for state in ["needs-login", "error", "starting", "needs-login"] {
            let result = plan([profile(state, keyExpired: true, expiresIn: -3600)], sent: sent)
            posted += result.post.map(\.key)
            sent = result.sent
        }
        #expect(posted == ["expired:p1"])
        #expect(sent == ["expired:p1"])
    }

    @Test func testExpiringBecomingExpiredSwapsKeys() {
        let first = plan([running(expiresIn: 3600)])
        #expect(first.sent == ["expiring:p1"])
        let second = plan([expired()], sent: first.sent)
        #expect(second.post.map(\.key) == ["expired:p1"])
        #expect(second.sent == ["expired:p1"])
    }

    @Test func testRenewalForgetsExpiringKey() {
        let first = plan([running(expiresIn: 3600)])
        let renewed = plan([running(expiresIn: 180 * 86400)], sent: first.sent)
        #expect(renewed.post.isEmpty)
        #expect(renewed.sent.isEmpty)
    }

    @Test func testLogoutForgetsExpiredKey() {
        let result = plan([profile("needs-login")], sent: ["expired:p1"])
        #expect(result.post.isEmpty)
        #expect(result.sent.isEmpty)
    }

    @Test func testAbsentProfileKeysDropped() {
        let result = plan([], sent: ["expired:p1", "expiring:p2"])
        #expect(result.sent.isEmpty)
    }
}
