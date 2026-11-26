import Foundation

/// A notification telling the user a profile needs, or will soon need,
/// sign-in.
public struct SignInNotification: Equatable {
    /// "expired:<profileID>" or "expiring:<profileID>".
    public var key: String
    public var profileID: String
    public var title: String
    public var body: String
}

/// Decides which sign-in notifications to post, one per episode per profile.
public enum SignInNotifications {
    /// Returns notifications to post now and the updated set of keys already
    /// notified. A key is forgotten only once its episode ends (signed in,
    /// key renewed, or expiring turned into expired), so the next episode
    /// notifies again. Transient states such as "starting" or "error" carry
    /// a profile's keys forward. Keys for absent profiles are dropped.
    public static func plan(profiles: [Profile], sent: Set<String>, now: Date,
                            locale: Locale = .current, timeZone: TimeZone = .current)
        -> (post: [SignInNotification], sent: Set<String>) {
        var post: [SignInNotification] = []
        var kept: Set<String> = []
        for profile in profiles {
            let running = profile.runtimeState == "running"
            let needsLogin = profile.runtimeState == "needs-login"
            let expiringKey = "expiring:\(profile.id)"
            let expiredKey = "expired:\(profile.id)"
            let endsExpiring = (running && !MenuModel.isExpiringSoon(profile, now: now)) ||
                (needsLogin && profile.keyExpired)
            let endsExpired = running || (needsLogin && !profile.keyExpired)
            if sent.contains(expiringKey) && !endsExpiring {
                kept.insert(expiringKey)
            }
            if sent.contains(expiredKey) && !endsExpired {
                kept.insert(expiredKey)
            }
            if let notification = notification(for: profile, now: now, locale: locale, timeZone: timeZone),
               !kept.contains(notification.key) {
                kept.insert(notification.key)
                post.append(notification)
            }
        }
        return (post, kept)
    }

    static func notification(for profile: Profile, now: Date, locale: Locale, timeZone: TimeZone) -> SignInNotification? {
        if profile.runtimeState == "needs-login" && profile.keyExpired {
            return SignInNotification(
                key: "expired:\(profile.id)", profileID: profile.id,
                title: "Sign in to \(profile.name)",
                body: "tailmix needs you to sign in to this tailnet again.")
        }
        if MenuModel.isExpiringSoon(profile, now: now), let expiry = profile.keyExpiry {
            let weekday = MenuModel.expiryWeekday(expiry, locale: locale, timeZone: timeZone)
            return SignInNotification(
                key: "expiring:\(profile.id)", profileID: profile.id,
                title: "\(profile.name) key expires \(weekday)",
                body: "Sign in again before then to stay connected.")
        }
        return nil
    }
}
