import AppIntents
import Foundation
import UserNotifications

/// Shortcuts action for an instant reminder when a real workout starts. Set it up in the
/// Shortcuts app: Automation → Apple Watch Workout → Is Started → Run Immediately → this action.
///
/// Like the heart rate check on the watch, it only reminds: it posts "Are you exercising?" and
/// changes nothing. It does nothing while Ask When Exercising is off, and in Log Only mode it
/// only writes to the log.
@available(iOS 16.0, *) struct ExerciseReminderIntent: AppIntent {
    // Title of the action in the Shortcuts app
    static var title: LocalizedStringResource = "Remind to set a temp target for exercise"

    // Description of the action in the Shortcuts app
    static var description = IntentDescription(
        "Shows Trio's \"Are you exercising?\" reminder. Run it from an Apple Watch Workout automation to be reminded as soon as a workout starts. Nothing is changed unless you pick a temp target or override."
    )

    static var parameterSummary: some ParameterSummary {
        Summary("Remind me to set a temp target")
    }

    @MainActor func perform() async throws -> some IntentResult {
        let settings = BaseIntentsRequest().settingsManager.settings
        guard settings.exercisePromptWatch else {
            info(.watch, "Workout reminder from Shortcuts ignored: Ask When Exercising is off")
            return .result()
        }
        guard !settings.exercisePromptLogOnly else {
            info(.watch, "Workout reminder from Shortcuts: would remind (log only)")
            return .result()
        }

        let body = String(
            localized: "Your workout has started. Set a temp target or override?",
            comment: "Exercise prompt body when a workout starts"
        )
        do {
            // Same identifiers and re-alerts as the watch's reminder, so the two never stack up
            try await ExerciseReminderNotifications.post(
                body: body,
                postedAt: Date(),
                repeatMinutes: settings.exercisePromptRepeat ? NSDecimalNumber(decimal: settings.exercisePromptRepeatMinutes).doubleValue : 0,
                repeatCount: NSDecimalNumber(decimal: settings.exercisePromptRepeatCount).intValue
            )
            info(.watch, "Workout reminder from Shortcuts shown")
        } catch {
            warning(.watch, "Could not show the workout reminder from Shortcuts", error: error)
        }
        return .result()
    }
}
