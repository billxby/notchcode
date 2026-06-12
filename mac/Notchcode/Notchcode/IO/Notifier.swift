// macOS notification banners for "an agent is blocked on you."
//
// When a session enters `.waiting` (Claude or Codex fired a PermissionRequest
// hook), the notch already turns yellow — but that's invisible if you've
// switched to another app. The agent is stalled until you answer, so we post a
// system banner you can click to jump straight to the right terminal window.
//
// Why this matters for Codex specifically: Codex asks for approval frequently,
// and (unlike Claude) gives us no Stop hook, so a missed approval can leave it
// parked indefinitely. A banner is the reliable "go look at me" nudge.
//
// Click handling routes through TerminalFocus, the same precise-window raise
// the notch uses, so clicking a banner lands you on the exact window — not just
// "some iTerm window."

import Foundation
import UserNotifications
import AppKit

@MainActor
final class Notifier: NSObject {
    static let shared = Notifier()
    private override init() { super.init() }

    /// userInfo key carrying the engine session id, so the click handler can
    /// resolve the session and focus its terminal. `nonisolated` so the
    /// nonisolated delegate callbacks can read it without a hop.
    nonisolated private static let sessionIDKey = "notchcode.sessionID"

    /// True once the user has been asked (granted or not). We still attempt to
    /// post — the center silently drops banners if denied, which is fine.
    private var authorizationRequested = false

    /// Call once at launch. Sets the delegate (required for foreground banners
    /// and click handling) and asks for notification permission. Safe to call
    /// before the user has done anything.
    func bootstrap() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard !authorizationRequested else { return }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error {
                print("[Notchcode] Notification authorization error: \(error)")
            }
        }
    }

    /// Post (or replace) the "needs input" banner for a waiting session. Called
    /// on the entry edge only — the engine guards re-fires so a session that
    /// stays waiting doesn't spam. Using the session id as the notification id
    /// means a repeat for the same session coalesces instead of stacking.
    func sessionNeedsInput(
        id: String,
        agent: Agent,
        project: String,
        toolDetail: String?
    ) {
        guard AppSettings.shared.notifyOnWaiting else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(agent.displayName) needs your input"
        var body = project.isEmpty ? "Waiting for your approval" : project
        if let toolDetail, !toolDetail.isEmpty {
            body += " · \(toolDetail)"
        }
        content.body = body
        content.sound = .default
        content.userInfo = [Self.sessionIDKey: id]

        // nil trigger → deliver immediately.
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[Notchcode] Failed to post notification: \(error)")
            }
        }
    }

    /// Pull any delivered/pending banner for a session that has stopped
    /// waiting (approval granted, or the turn ended). Keeps Notification Center
    /// from accumulating stale "needs input" cards the user already resolved.
    func clearWaiting(id: String) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show the banner even when Notchcode happens to be the active app —
    /// without this, foreground notifications are suppressed by default.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// User clicked the banner → raise the exact terminal window for that
    /// session, mirroring the notch's tap-to-focus.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionID = info[Notifier.sessionIDKey] as? String
        Task { @MainActor in
            if let sessionID,
               let session = SessionStateEngine.shared.session(id: sessionID),
               let bundleID = session.terminalBundleID {
                TerminalFocus.focus(bundleID: bundleID, projectHint: session.project)
            }
            completionHandler()
        }
    }
}
