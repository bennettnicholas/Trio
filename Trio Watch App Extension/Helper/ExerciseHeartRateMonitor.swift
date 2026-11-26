import CoreMotion
import Foundation
import HealthKit
import UserNotifications
import WatchConnectivity
import WatchKit

/// Which screen tapping the exercise prompt opens
enum ExercisePromptDestination {
    case tempTarget
    case override
}

/// Reminds the user to set a temp target when they've been exercising for a while.
///
/// Uses only data the Apple Watch already records: heart rate from Health, plus steps and
/// motion activity from Core Motion. No workout session, so battery use stays near zero.
///
/// Trio only reminds. Nothing is changed until the user picks a temp target or override.
///
/// Opt-in: off by default and turned on in Trio's iPhone settings
/// (Settings → Apple Watch → Ask When Exercising). While it is off, the watch app never asks
/// for Health or Motion access, never reads either, and schedules no checks.
///
/// How it decides (see `evaluate`):
/// - Each check looks at the last 15 minutes. Most readings must be near the user's
///   exercise heart rate for most of that time ("sustained").
/// - A minute of walking around the house can't pass that. To be sure, the reminder also
///   needs a second sustained check at least 5 minutes later, unless steps or motion show
///   clear movement. Activities with few steps, like hockey, still pass on heart rate alone.
/// - So the reminder comes roughly 15 to 25 minutes into sustained activity.
///
/// Checks run in the background about 4 times an hour (needs a Trio complication on the
/// active watch face), when an iPhone update wakes the app (about every 5 minutes), and
/// every time the watch app is opened. Every check is recorded in `history` and logged.
final class ExerciseHeartRateMonitor {
    static let shared = ExerciseHeartRateMonitor()

    // MARK: - Tunables

    /// Default exercise heart rate until the iPhone sends the user's setting. A brisk walk
    /// puts an average adult at about 100–110 bpm, so 105 sits in the middle.
    static let defaultExerciseBPM: Double = 105
    /// Same bounds as the iPhone picker, so a bad value can't disable or flood the reminder
    static let exerciseBPMRange: ClosedRange<Double> = 80 ... 180
    /// A reading counts as elevated at this share of the exercise heart rate. The setting is
    /// an average, so about half of real exercise readings fall below it.
    static let elevatedFactor: Double = 0.9
    /// How far back each check looks
    static let window: TimeInterval = 15 * 60
    /// Apple Watch saves heart rate to Health in batches, so the newest saved reading is often
    /// 1–5 minutes old in the background. Look back this much further to cover that.
    static let healthWriteDelayAllowance: TimeInterval = 3 * 60
    /// The newest reading must be this recent, so we don't remind after the user stopped
    static let maximumReadingAge: TimeInterval = 5 * 60
    /// Readings must span this much of the window
    static let minimumCoverage: TimeInterval = 10 * 60
    /// Share of readings that must be elevated. Not higher, so rests between hockey shifts
    /// or waiting at a crossing don't reset everything.
    static let elevatedShare: Double = 0.7
    /// Too few readings say nothing about 15 minutes
    static let minimumReadings = 10
    /// A second sustained check must come at least this long after the first
    static let confirmationDelay: TimeInterval = 5 * 60
    /// Steps in the window that count as clear movement (a brisk walk is ~100 steps a minute)
    static let movingSteps = 600
    /// Minutes of walking, running or cycling in the window that count as clear movement
    static let movingMinutes: Double = 8
    /// After reminding, wait this long before reminding again
    static let promptCooldown: TimeInterval = 60 * 60
    /// "Not now" silences the reminder for this long
    static let notNowSnooze: TimeInterval = 2 * 60 * 60
    /// watchOS treats this as "no earlier than"; it caps apps at about 4 wakes an hour anyway
    static let refreshInterval: TimeInterval = 15 * 60
    /// Checks piggybacked on iPhone updates run at most this often. Short, because the iPhone
    /// often sends two updates a few seconds apart; a longer gap skipped real wakes in testing.
    static let phoneUpdateCheckGap: TimeInterval = 90
    /// How many checks the on-watch history keeps
    static let historyLimit = 100

    static let refreshIdentifier = "Trio.exerciseHeartRateCheck"

    // MARK: - Notification identifiers

    enum PromptNotification {
        static let category = "Trio.exercisePrompt"
        static let requestIdentifier = WatchMessageKeys.exercisePromptNotificationID
        static let tempTargetAction = "Trio.exercisePrompt.tempTarget"
        static let overrideAction = "Trio.exercisePrompt.override"
        static let notNowAction = "Trio.exercisePrompt.notNow"
    }

    private enum DefaultsKey {
        static let lastPromptDate = "Trio.exercisePrompt.lastPromptDate"
        static let sustainedSince = "Trio.exercisePrompt.sustainedSince"
        static let nextBackgroundCheck = "Trio.exercisePrompt.nextBackgroundCheck"
        static let lastPhoneUpdateCheck = "Trio.exercisePrompt.lastPhoneUpdateCheck"
        static let snoozedUntil = "Trio.exercisePrompt.snoozedUntil"
        static let isEnabled = "Trio.exercisePrompt.isEnabled"
        static let exerciseBPM = "Trio.exercisePrompt.exerciseBPM"
        static let logOnly = "Trio.exercisePrompt.logOnly"
        static let history = "Trio.exercisePrompt.history"
    }

    /// The user's settings, stored on the watch so background checks have them without the phone
    struct Config {
        /// The user's average heart rate while exercising
        let exerciseBPM: Double
        /// Test mode: check and record everything, but never notify
        let logOnly: Bool

        /// Readings at or above this count as elevated
        var elevatedBPM: Double { (exerciseBPM * ExerciseHeartRateMonitor.elevatedFactor).rounded() }
    }

    private let healthStore = HKHealthStore()
    private let heartRateType = HKQuantityType(.heartRate)
    private let pedometer = CMPedometer()
    private let activityManager = CMMotionActivityManager()
    private let defaults = UserDefaults.standard
    private let log = WatchLogger.shared
    /// Checks can start from several places at once; this keeps the history and streak consistent
    private let checkLock = NSLock()

    private init() {}

    // MARK: - Settings

    var config: Config {
        let bpm = defaults.object(forKey: DefaultsKey.exerciseBPM) as? Double ?? Self.defaultExerciseBPM
        return Config(
            exerciseBPM: bpm.clamped(to: Self.exerciseBPMRange),
            logOnly: defaults.bool(forKey: DefaultsKey.logOnly)
        )
    }

    /// Called with the settings the iPhone sends in every watch state update.
    func setConfig(exerciseBPM: Double?, logOnly: Bool?) {
        let current = config
        if let exerciseBPM, exerciseBPM != current.exerciseBPM {
            defaults.set(exerciseBPM.clamped(to: Self.exerciseBPMRange), forKey: DefaultsKey.exerciseBPM)
            log.info(.exercise, "Exercise heart rate set to \(Int(exerciseBPM)) bpm")
        }
        if let logOnly, logOnly != current.logOnly {
            defaults.set(logOnly, forKey: DefaultsKey.logOnly)
            // Start each mode fresh, so a log-only "would remind" doesn't block a real one
            defaults.removeObject(forKey: DefaultsKey.lastPromptDate)
            defaults.removeObject(forKey: DefaultsKey.sustainedSince)
            log.info(.exercise, "Log-only test mode turned \(logOnly ? "on" : "off")")
        }
    }

    /// Stored on the watch so background checks know the setting without the phone
    var isEnabled: Bool {
        defaults.bool(forKey: DefaultsKey.isEnabled)
    }

    /// Called with the setting the iPhone sends in every watch state update.
    func setEnabled(_ enabled: Bool, appIsActive: Bool) {
        guard enabled != isEnabled else { return }
        defaults.set(enabled, forKey: DefaultsKey.isEnabled)
        log.info(.exercise, "Ask When Exercising turned \(enabled ? "on" : "off")")

        if enabled {
            // Health and Motion access can only be requested while the app is open
            if appIsActive { appDidBecomeActive() }
        } else {
            defaults.removeObject(forKey: DefaultsKey.sustainedSince)
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [PromptNotification.requestIdentifier])
        }
    }

    // MARK: - Entry points

    /// Call when the app becomes active: asks for permissions once, checks right away,
    /// and makes sure a background check is scheduled. Does nothing while the setting is off.
    func appDidBecomeActive() {
        guard isEnabled else { return }
        Task {
            await requestPermissionsIfNeeded()
            await check(reason: .appOpened)
            // Only fill a gap: rescheduling here would push a pending check back 15 minutes
            // every time the app is opened
            await scheduleNextBackgroundCheck(onlyIfNonePending: true)
        }
    }

    /// Runs from the SwiftUI `.backgroundTask(.appRefresh)` handler.
    func handleBackgroundRefresh() async {
        // Turned off since this was scheduled: don't read and don't schedule another
        guard isEnabled else { return }
        await check(reason: .backgroundRefresh)
        await scheduleNextBackgroundCheck()
    }

    /// Trio's iPhone sends a state update after every loop (about every 5 minutes), and
    /// watchOS may wake the watch app in the background to receive it. This piggybacks a
    /// check on those wakes, so the reminder can come sooner than the 15-minute refreshes allow.
    ///
    /// Called after the update has been applied, and the check runs in its own task, so it
    /// never delays or changes how the update itself is handled. Sends nothing to the phone.
    func phoneUpdateArrived(appIsActive: Bool) {
        // While the app is open, opening it already ran a check
        guard isEnabled, !appIsActive else { return }

        let now = Date()
        if let last = defaults.object(forKey: DefaultsKey.lastPhoneUpdateCheck) as? Date,
           now.timeIntervalSince(last) < Self.phoneUpdateCheckGap
        {
            return
        }
        defaults.set(now, forKey: DefaultsKey.lastPhoneUpdateCheck)

        Task { await check(reason: .phoneUpdate) }
    }

    /// "Not now" on the notification.
    func snooze() {
        let until = Date().addingTimeInterval(Self.notNowSnooze)
        defaults.set(until, forKey: DefaultsKey.snoozedUntil)
        log.info(.exercise, "Reminder snoozed until \(until.formatted(date: .omitted, time: .shortened))")
    }

    static func makeNotificationCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: PromptNotification.category,
            actions: [
                UNNotificationAction(
                    identifier: PromptNotification.tempTargetAction,
                    title: String(localized: "Temp Target", comment: "Exercise prompt action that opens temp targets"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: PromptNotification.overrideAction,
                    title: String(localized: "Override", comment: "Exercise prompt action that opens overrides"),
                    options: [.foreground]
                ),
                UNNotificationAction(
                    identifier: PromptNotification.notNowAction,
                    title: String(localized: "Not now", comment: "Exercise prompt action that snoozes the prompt"),
                    options: []
                )
            ],
            intentIdentifiers: [],
            options: []
        )
    }

    // MARK: - Check

    enum CheckReason: String, Codable {
        case appOpened = "app opened"
        case backgroundRefresh = "background refresh"
        case phoneUpdate = "phone update"
    }

    private func check(reason: CheckReason) async {
        guard isEnabled else { return }
        let now = Date()
        let config = self.config

        if let snoozedUntil = defaults.object(forKey: DefaultsKey.snoozedUntil) as? Date, snoozedUntil > now {
            record(ExerciseCheckRecord(date: now, reason: reason, outcome: .skippedSnoozed))
            return
        }
        if let lastPrompt = defaults.object(forKey: DefaultsKey.lastPromptDate) as? Date,
           now.timeIntervalSince(lastPrompt) < Self.promptCooldown
        {
            record(ExerciseCheckRecord(date: now, reason: reason, outcome: .skippedCooldown))
            return
        }

        let start = now.addingTimeInterval(-(Self.window + Self.healthWriteDelayAllowance))
        let readings: [Reading]
        do {
            readings = try await fetchReadings(since: start)
        } catch {
            // errorDatabaseInaccessible means the watch is locked (off the wrist)
            log.warning(.exercise, "Check (\(reason.rawValue)) could not read heart rate", error: error)
            record(ExerciseCheckRecord(date: now, reason: reason, outcome: .readFailed))
            return
        }
        let motion = await fetchMotion(from: now.addingTimeInterval(-Self.window), to: now)

        // Only one check at a time may read and update the streak
        let result = checkLock.withLock {
            let sustainedSince = defaults.object(forKey: DefaultsKey.sustainedSince) as? Date
            let result = Self.evaluate(readings, motion: motion, sustainedSince: sustainedSince, now: now, config: config)
            if result.isSustained {
                if sustainedSince == nil { defaults.set(now, forKey: DefaultsKey.sustainedSince) }
            } else {
                defaults.removeObject(forKey: DefaultsKey.sustainedSince)
            }
            if result.shouldRemind {
                // Cooldown starts now in both modes; the streak starts over after a reminder
                defaults.set(now, forKey: DefaultsKey.lastPromptDate)
                defaults.removeObject(forKey: DefaultsKey.sustainedSince)
            }
            return result
        }

        let outcome: ExerciseCheckRecord.Outcome = result.shouldRemind
            ? (config.logOnly ? .wouldRemind : .reminded)
            : (result.isSustained ? .sustainedWaiting : .notSustained)
        record(ExerciseCheckRecord(date: now, reason: reason, outcome: outcome, evaluation: result, motion: motion))

        guard result.shouldRemind, !config.logOnly else { return }
        await postPrompt()
    }

    struct Reading {
        let start: Date
        let end: Date
        let bpm: Double
        /// A series sample stands for several readings
        let count: Int
    }

    struct Motion: Codable {
        /// nil when Motion access isn't granted or the query failed
        let steps: Int?
        /// Minutes classified as walking, running or cycling; nil when unavailable
        let activeMinutes: Double?

        var isClearlyMoving: Bool {
            (steps ?? 0) >= ExerciseHeartRateMonitor.movingSteps ||
                (activeMinutes ?? 0) >= ExerciseHeartRateMonitor.movingMinutes
        }
    }

    struct Evaluation: Codable {
        let readingCount: Int
        let minBPM: Int
        let maxBPM: Int
        let elevatedBPM: Int
        let elevatedPercent: Int
        let coverageMinutes: Int
        let newestAgeSeconds: Int
        let isSustained: Bool
        let shouldRemind: Bool
        /// Why it did or didn't remind, in a few words
        let why: String
    }

    /// Pure, so the rule can be tuned from the logs without touching HealthKit or Core Motion.
    static func evaluate(
        _ readings: [Reading],
        motion: Motion,
        sustainedSince: Date?,
        now: Date,
        config: Config
    ) -> Evaluation {
        let total = readings.reduce(0) { $0 + $1.count }
        let elevatedBPM = config.elevatedBPM
        guard total >= minimumReadings, let first = readings.first, let last = readings.last else {
            return Evaluation(
                readingCount: total, minBPM: 0, maxBPM: 0, elevatedBPM: Int(elevatedBPM), elevatedPercent: 0,
                coverageMinutes: 0, newestAgeSeconds: 0, isSustained: false, shouldRemind: false,
                why: "too few readings"
            )
        }

        let elevated = readings.filter { $0.bpm >= elevatedBPM }.reduce(0) { $0 + $1.count }
        let share = Double(elevated) / Double(total)
        let coverage = last.end.timeIntervalSince(first.start)
        let newestAge = now.timeIntervalSince(last.end)

        let (isSustained, shouldRemind, why): (Bool, Bool, String) =
            if share < elevatedShare {
                (false, false, "heart rate not high enough for long enough")
            } else if coverage < minimumCoverage {
                (false, false, "readings cover too little time")
            } else if newestAge > maximumReadingAge {
                (false, false, "no recent readings")
            } else if motion.isClearlyMoving {
                (true, true, "sustained, and steps or motion confirm it")
            } else if let sustainedSince, now.timeIntervalSince(sustainedSince) >= confirmationDelay {
                (true, true, "sustained on two checks 5+ minutes apart")
            } else {
                (true, false, "sustained, waiting for a second check to confirm")
            }

        return Evaluation(
            readingCount: total,
            minBPM: Int(readings.map(\.bpm).min() ?? 0),
            maxBPM: Int(readings.map(\.bpm).max() ?? 0),
            elevatedBPM: Int(elevatedBPM),
            elevatedPercent: Int(share * 100),
            coverageMinutes: Int(coverage / 60),
            newestAgeSeconds: Int(newestAge),
            isSustained: isSustained,
            shouldRemind: shouldRemind,
            why: why
        )
    }

    private func fetchReadings(since start: Date) async throws -> [Reading] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(
                type: heartRateType,
                predicate: HKQuery.predicateForSamples(withStart: start, end: nil)
            )],
            sortDescriptors: [SortDescriptor(\.startDate, order: .forward)]
        )
        let unit = HKUnit.count().unitDivided(by: .minute())
        let samples = try await descriptor.result(for: healthStore)

        return samples.map { sample in
            if let series = sample as? HKDiscreteQuantitySample {
                return Reading(
                    start: series.startDate,
                    end: series.endDate,
                    bpm: series.averageQuantity.doubleValue(for: unit),
                    count: max(series.count, 1)
                )
            }
            return Reading(
                start: sample.startDate,
                end: sample.endDate,
                bpm: sample.quantity.doubleValue(for: unit),
                count: 1
            )
        }
    }

    /// Steps and motion activity the watch has already recorded. Both are optional evidence:
    /// if Motion access is off or a query fails, the check runs on heart rate alone.
    private func fetchMotion(from start: Date, to end: Date) async -> Motion {
        var steps: Int?
        if CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() == .authorized {
            steps = await withCheckedContinuation { continuation in
                pedometer.queryPedometerData(from: start, to: end) { data, _ in
                    continuation.resume(returning: data?.numberOfSteps.intValue)
                }
            }
        }

        var activeMinutes: Double?
        if CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .authorized {
            activeMinutes = await withCheckedContinuation { continuation in
                activityManager.queryActivityStarting(from: start, to: end, to: OperationQueue()) { activities, _ in
                    guard let activities else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Each activity lasts until the next one starts
                    var seconds: TimeInterval = 0
                    for (index, activity) in activities.enumerated() {
                        guard activity.confidence != .low,
                              activity.walking || activity.running || activity.cycling
                        else { continue }
                        let from = max(activity.startDate, start)
                        let until = index + 1 < activities.count ? activities[index + 1].startDate : end
                        seconds += max(0, until.timeIntervalSince(from))
                    }
                    continuation.resume(returning: seconds / 60)
                }
            }
        }

        return Motion(steps: steps, activeMinutes: activeMinutes)
    }

    // MARK: - History and logging

    /// The most recent checks, newest first, for the watch's check history screen
    var history: [ExerciseCheckRecord] {
        guard let data = defaults.data(forKey: DefaultsKey.history) else { return [] }
        return (try? JSONDecoder().decode([ExerciseCheckRecord].self, from: data)) ?? []
    }

    func clearHistory() {
        defaults.removeObject(forKey: DefaultsKey.history)
    }

    /// Saves the check for the history screen and writes it to the watch log (included in
    /// Trio's shared logs), so a test can be reviewed on the watch or from the iPhone.
    private func record(_ entry: ExerciseCheckRecord) {
        log.info(.exercise, entry.logLine)

        checkLock.withLock {
            var entries = history
            entries.insert(entry, at: 0)
            if entries.count > Self.historyLimit { entries.removeLast(entries.count - Self.historyLimit) }
            if let data = try? JSONEncoder().encode(entries) {
                defaults.set(data, forKey: DefaultsKey.history)
            }
        }
    }

    // MARK: - Notification

    private func postPrompt() async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Are you exercising?", comment: "Exercise prompt title")
        content.body = String(
            localized: "Your heart rate has been up for a while. Set a temp target or override?",
            comment: "Exercise prompt body"
        )
        content.sound = .default
        content.categoryIdentifier = PromptNotification.category

        let request = UNNotificationRequest(
            identifier: PromptNotification.requestIdentifier,
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.info(.exercise, "Asked \"Are you exercising?\"")
        } catch {
            log.error(.exercise, "Could not post the exercise prompt", error: error)
        }

        sendPromptToPhone(body: content.body)
    }

    /// A notification the watch app posts only ever shows on the watch, so ask Trio on the
    /// iPhone to post the same prompt there. `transferUserInfo` is queued and delivered even
    /// when the iPhone app is in the background. The iPhone uses the same identifier, so a
    /// copy forwarded back to the watch replaces this one instead of showing twice.
    private func sendPromptToPhone(body: String) {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else {
            log.warning(.exercise, "Could not send the prompt to iPhone: connection not active")
            return
        }
        session.transferUserInfo([WatchMessageKeys.exercisePrompt: body])
        log.info(.exercise, "Sent the prompt to iPhone")
    }

    // MARK: - Permissions and scheduling

    private func requestPermissionsIfNeeded() async {
        if HKHealthStore.isHealthDataAvailable() {
            do {
                let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: [heartRateType])
                if status == .shouldRequest {
                    try await healthStore.requestAuthorization(toShare: [], read: [heartRateType])
                    log.info(.exercise, "Asked for heart rate access")
                }
            } catch {
                log.error(.exercise, "Heart rate access request failed", error: error)
            }
        } else {
            log.warning(.exercise, "Health data is not available on this watch")
        }

        // Motion access has no request call: the first query asks, so make a tiny one
        // while the app is open
        if CMMotionActivityManager.isActivityAvailable(), CMMotionActivityManager.authorizationStatus() == .notDetermined {
            let now = Date()
            _ = await fetchMotionPermissionProbe(from: now.addingTimeInterval(-60), to: now)
            log.info(.exercise, "Asked for Motion access")
        }

        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error(.exercise, "Notification permission request failed", error: error)
        }
    }

    private func fetchMotionPermissionProbe(from start: Date, to end: Date) async -> Bool {
        await withCheckedContinuation { continuation in
            activityManager.queryActivityStarting(from: start, to: end, to: OperationQueue()) { _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    @MainActor private func scheduleNextBackgroundCheck(onlyIfNonePending: Bool = false) {
        let now = Date()
        if onlyIfNonePending,
           let pending = defaults.object(forKey: DefaultsKey.nextBackgroundCheck) as? Date,
           pending > now
        {
            return
        }
        let preferredDate = now.addingTimeInterval(Self.refreshInterval)
        defaults.set(preferredDate, forKey: DefaultsKey.nextBackgroundCheck)
        WKApplication.shared().scheduleBackgroundRefresh(
            withPreferredDate: preferredDate,
            userInfo: Self.refreshIdentifier as NSString
        ) { [log] error in
            if let error {
                log.error(.exercise, "Could not schedule the next heart rate check", error: error)
            }
        }
    }
}

/// One exercise check, kept on the watch for the check history screen
struct ExerciseCheckRecord: Codable, Identifiable {
    enum Outcome: String, Codable {
        case reminded
        case wouldRemind
        case sustainedWaiting
        case notSustained
        case skippedSnoozed
        case skippedCooldown
        case readFailed

        var label: String {
            switch self {
            case .reminded: return String(localized: "Reminded", comment: "Exercise check outcome")
            case .wouldRemind: return String(localized: "Would remind (log only)", comment: "Exercise check outcome")
            case .sustainedWaiting: return String(localized: "Sustained, confirming", comment: "Exercise check outcome")
            case .notSustained: return String(localized: "Not exercising", comment: "Exercise check outcome")
            case .skippedSnoozed: return String(localized: "Skipped: snoozed", comment: "Exercise check outcome")
            case .skippedCooldown: return String(localized: "Skipped: reminded recently", comment: "Exercise check outcome")
            case .readFailed: return String(localized: "Couldn't read heart rate", comment: "Exercise check outcome")
            }
        }
    }

    var id: Date { date }
    let date: Date
    let reason: ExerciseHeartRateMonitor.CheckReason
    let outcome: Outcome
    var evaluation: ExerciseHeartRateMonitor.Evaluation?
    var motion: ExerciseHeartRateMonitor.Motion?

    var logLine: String {
        var line = "Check (\(reason.rawValue)): \(outcome.rawValue)"
        if let evaluation {
            line += " — \(evaluation.readingCount) readings, \(evaluation.minBPM)-\(evaluation.maxBPM) bpm, " +
                "\(evaluation.elevatedPercent)% ≥ \(evaluation.elevatedBPM), covering \(evaluation.coverageMinutes) min, " +
                "newest \(evaluation.newestAgeSeconds)s old; \(evaluation.why)"
        }
        if let motion {
            line += "; steps \(motion.steps.map(String.init) ?? "n/a"), " +
                "active \(motion.activeMinutes.map { String(Int($0)) } ?? "n/a") min"
        }
        return line
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
