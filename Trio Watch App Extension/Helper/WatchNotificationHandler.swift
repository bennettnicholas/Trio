import Foundation
import UserNotifications
import WatchConnectivity

final class WatchNotificationHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WatchNotificationHandler()

    override private init() {
        super.init()
    }

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        registerCategories(on: center)
    }

    private func registerCategories(on center: UNUserNotificationCenter) {
        center.getNotificationCategories { existingCategories in
            let glucoseCategory = NotificationCategoryFactory.createGlucoseCategory()

            var categories = existingCategories
            categories.update(with: glucoseCategory)
            categories.update(with: ExerciseHeartRateMonitor.makeNotificationCategory())
            // UNUserNotificationCenter methods should be called on main thread
            Task { @MainActor in
                center.setNotificationCategories(categories)
            }
        }
    }

    /// UNUserNotificationCenterDelegate method called when user interacts with a notification on watch.
    /// This can be called off the main thread. WCSession.transferUserInfo is thread-safe.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        if response.notification.request.content.categoryIdentifier == ExerciseHeartRateMonitor.PromptNotification.category {
            handleExercisePrompt(actionIdentifier: response.actionIdentifier)
            return
        }

        guard let action = NotificationResponseAction(rawValue: response.actionIdentifier) else { return }
        sendSnoozeRequest(minutes: action.minutes)
    }

    /// Shows the exercise prompt as a banner when it fires while the app is open
    /// (the check runs every time the app opens). Other notifications keep their current behavior.
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if notification.request.content.categoryIdentifier == ExerciseHeartRateMonitor.PromptNotification.category {
            completionHandler([.banner, .sound])
        } else {
            completionHandler([])
        }
    }

    /// Tapping the prompt opens temp targets; the actions open temp targets or overrides,
    /// or snooze the prompt. Nothing is applied until the user picks a preset.
    private func handleExercisePrompt(actionIdentifier: String) {
        // Any response (tap, action, swipe away) acknowledges it and stops the re-alerts
        ExerciseHeartRateMonitor.shared.acknowledge(action: actionIdentifier, fromPhone: false)

        let destination: ExercisePromptDestination?
        switch actionIdentifier {
        case ExerciseHeartRateMonitor.PromptNotification.notNowAction:
            destination = nil
        case ExerciseHeartRateMonitor.PromptNotification.overrideAction:
            destination = .override
        case ExerciseHeartRateMonitor.PromptNotification.tempTargetAction,
             UNNotificationDefaultActionIdentifier:
            destination = .tempTarget
        default:
            destination = nil
        }

        guard let destination else { return }
        WatchLogger.shared.info(.exercise, "Prompt opened \(destination == .override ? "overrides" : "temp targets")")
        Task { @MainActor in
            WatchState.shared.exercisePromptDestination = destination
        }
    }

    /// Sends snooze request to iPhone via WatchConnectivity.
    /// WCSession.transferUserInfo is thread-safe and can be called from any thread.
    /// Relies on the watch app's WCSession owner (e.g., WatchState) to handle
    /// session activation and delegate management.
    /// A duration of 0 ends the active snooze.
    func sendSnoozeRequest(minutes: Int) {
        guard WCSession.isSupported() else { return }

        let payload: [String: Any] = [WatchMessageKeys.snoozeDuration: minutes]
        let session = WCSession.default

        // Try sendMessage first if session is reachable and activated (faster, immediate delivery)
        // Fall back to transferUserInfo if not reachable or if sendMessage fails
        if session.isReachable, session.activationState == .activated {
            session.sendMessage(payload, replyHandler: nil) { _ in
                // Fallback to transferUserInfo if sendMessage fails
                session.transferUserInfo(payload)
            }
        } else {
            // Session not reachable or not activated - use transferUserInfo (queued delivery)
            session.transferUserInfo(payload)
        }
    }
}
