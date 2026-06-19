import Foundation
import UserNotifications
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Drives a Dynamic Island / Lock Screen Live Activity plus a completion
/// notification for a long-running AI image task (Astria edit / extend), so the
/// user sees "AI In Progress" and is alerted when the result arrives — even after
/// leaving the app while it finishes in its background-task window.
///
/// The Live Activity *display* requires a Widget Extension target (see
/// `LiveActivity/README.md`). Without it, `Activity.request` simply throws and we
/// fall back to the local notification — nothing crashes. The notification path
/// works on its own with no extension.
@MainActor
final class AIProgressActivity {
    private var activityID: String?

    /// Start: request notification permission and (when possible) raise the activity.
    func begin(title: String, detail: String) {
        AINotifications.requestAuthorization()
        #if canImport(ActivityKit)
        guard #available(iOS 16.2, *), ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = AIActivityAttributes.ContentState(phase: "AI In Progress", detail: detail, done: false)
        do {
            let activity = try Activity.request(
                attributes: AIActivityAttributes(title: title),
                content: ActivityContent(state: state, staleDate: nil))
            activityID = activity.id
        } catch {
            activityID = nil
        }
        #endif
    }

    /// Finish: end the Live Activity with a final state and post the notification.
    func finish(success: Bool, message: String) {
        AINotifications.post(title: success ? "AI images ready" : "AI couldn’t finish", body: message)
        #if canImport(ActivityKit)
        if #available(iOS 16.2, *), let id = activityID,
           let activity = Activity<AIActivityAttributes>.activities.first(where: { $0.id == id }) {
            let state = AIActivityAttributes.ContentState(phase: success ? "Ready" : "Failed", detail: message, done: true)
            Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now + 5)) }
        }
        #endif
        activityID = nil
    }
}

/// Thin wrapper over `UNUserNotificationCenter` for the "AI images received" alert.
enum AINotifications {
    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))   // nil = deliver now
    }
}
