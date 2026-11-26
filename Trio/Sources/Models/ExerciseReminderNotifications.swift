import Foundation
import UserNotifications

/// The "Are you exercising?" reminder, shared by Trio on the iPhone and the watch app, so both
/// post it with the same identifiers. When the iPhone is locked it forwards its copy to the
/// watch, and a matching identifier replaces the watch's own copy instead of showing it twice.
///
/// Re-alerts: the reminder repeats a few times until the user taps, dismisses or snoozes it on
/// either device. The repeats are scheduled up front as ordinary local notifications, because
/// neither app is guaranteed to be running when one is due.
enum ExerciseReminderNotifications {
    static let category = "Trio.exercisePrompt"
    static let identifier = WatchMessageKeys.exercisePromptNotificationID
    static let tempTargetAction = "Trio.exercisePrompt.tempTarget"
    static let overrideAction = "Trio.exercisePrompt.override"
    static let notNowAction = "Trio.exercisePrompt.notNow"
    /// Same bounds as the iPhone picker
    static let maxRepeats = 5

    static func repeatIdentifier(_ number: Int) -> String {
        "\(identifier).repeat.\(number)"
    }

    static var allIdentifiers: [String] {
        [identifier] + (1 ... maxRepeats).map(repeatIdentifier)
    }

    static func makeCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: category,
            actions: [
                UNNotificationAction(
                    identifier: tempTargetAction,
                    title: String(localized: "Temp Target", comment: "Exercise prompt action that opens temp targets"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: overrideAction,
                    title: String(localized: "Override", comment: "Exercise prompt action that opens overrides"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: notNowAction,
                    title: String(localized: "Not now", comment: "Exercise prompt action that snoozes the prompt"),
                    options: []
                )
            ],
            intentIdentifiers: [],
            // Swiping the reminder away also counts as seeing it, and stops the repeats
            options: [.customDismissAction]
        )
    }

    /// Posts the reminder now and schedules its repeats.
    /// - Parameters:
    ///   - postedAt: when the first reminder went out. The iPhone passes the watch's time, so
    ///     both devices repeat at the same moments.
    ///   - repeatMinutes: minutes between repeats; 0 turns repeats off
    ///   - repeatCount: how many repeats at most
    static func post(body: String, postedAt: Date, repeatMinutes: Double, repeatCount: Int) async throws {
        let center = UNUserNotificationCenter.current()
        // A new reminder replaces any repeats still pending from the last one
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)

        try await center.add(UNNotificationRequest(
            identifier: identifier,
            content: content(body: body),
            trigger: nil
        ))

        guard repeatMinutes > 0 else { return }
        let now = Date()
        for number in 1 ... min(max(repeatCount, 0), maxRepeats) {
            let due = postedAt.addingTimeInterval(Double(number) * repeatMinutes * 60)
            // Already past (the iPhone got the watch's message late): skip it
            guard due.timeIntervalSince(now) > 1 else { continue }
            try await center.add(UNNotificationRequest(
                identifier: repeatIdentifier(number),
                content: content(body: body),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: due.timeIntervalSince(now), repeats: false)
            ))
        }
    }

    /// The user tapped, dismissed or snoozed the reminder: stop the repeats and clear it away.
    static func cancelAll() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: allIdentifiers)
        center.removeDeliveredNotifications(withIdentifiers: allIdentifiers)
    }

    private static func content(body: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Are you exercising?", comment: "Exercise prompt title")
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        // Groups the first reminder and its repeats together
        content.threadIdentifier = category
        return content
    }
}
