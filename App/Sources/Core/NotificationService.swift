import Foundation
import UserNotifications
import NodetermKit

/// LOCAL notifications for finished / needs-you edges (SPEC §9.6). No APNs, no server push: this
/// fires only while the app process is alive — foreground, the seconds iOS grants a just-
/// backgrounded app, and background-refresh windows. True delivery when the app is fully closed
/// needs an APNs server component (out of scope; the Settings text says so).
///
/// The edge decision is the pure `pendingNotifications` (NodetermKit); this is the thin UNerated
/// side: authorization, firing, and the app-icon badge = unread count.
@MainActor
final class NotificationService {
    private let center = UNUserNotificationCenter.current()
    private var authorized = false

    /// Ask once. Cheap to call repeatedly — the system remembers the grant.
    func requestAuthorizationIfNeeded() {
        Task { @MainActor in
            let status = await center.notificationSettings().authorizationStatus
            switch status {
            case .authorized, .provisional, .ephemeral:
                self.authorized = true
            case .notDetermined:
                self.authorized = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            default:
                self.authorized = false
            }
        }
    }

    /// Fire the notifications a status batch produced, and update the app-icon badge. `nameFor`
    /// resolves a node id to a human title (session name / node title) for the banner body.
    func deliver(_ pending: [PendingNotification], badgeCount: Int, nameFor: (String) -> String?) {
        setBadge(badgeCount)
        guard authorized, !pending.isEmpty else { return }
        for p in pending {
            let content = UNMutableNotificationContent()
            let name = nameFor(p.nodeId) ?? "A session"
            switch p.kind {
            case .finished:
                content.title = "Session finished"
                content.body = name
            case .needsYou:
                content.title = "Needs your response"
                content.body = name
            }
            content.sound = .default
            content.userInfo = ["nodeId": p.nodeId]
            // A nil trigger fires immediately. The id is per-edge so a re-fire for the same node
            // replaces the previous banner instead of stacking.
            let req = UNNotificationRequest(identifier: "edge:\(p.nodeId)", content: content, trigger: nil)
            center.add(req)
        }
    }

    /// Keep the app-icon badge in sync with the unread count (also clears it on 0).
    func setBadge(_ count: Int) {
        center.setBadgeCount(count)
    }
}
