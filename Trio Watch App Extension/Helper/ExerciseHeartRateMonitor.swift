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

/// Watches the heart rate the Apple Watch already records and asks
/// "Are you exercising?" when it has stayed elevated.
///
/// Trio only asks. Nothing is changed until the user picks a temp target or
/// override themselves.
///
/// Opt-in: off by default and turned on in Trio's iPhone settings
/// (Settings → Apple Watch → Ask When Exercising). While it is off, the watch app
/// never asks for Health access, never reads heart rate and schedules no checks.
///
/// Checks run:
/// - in the background, about 4 times an hour (watchOS only grants this
///   budget while a Trio complication is on the active watch face), and
/// - every time the watch app is opened.
final class ExerciseHeartRateMonitor {
    static let shared = ExerciseHeartRateMonitor()

    // MARK: - Tunables

    /// Defaults until the iPhone sends the user's settings
    static let defaultThresholdBPM: Double = 100
    static let defaultMinutes: Double = 10
    /// Same bounds as the iPhone pickers, so a bad value can't disable or flood the prompt
    static let thresholdRange: ClosedRange<Double> = 80 ... 180
    static let minutesRange: ClosedRange<Double> = 5 ... 30
    /// The readings have to cover this share of the window, not just its last minute
    static let minimumCoverageShare: Double = 0.8
    /// The newest reading must be this recent, so we don't ask after the user stopped.
    /// Apple Watch saves heart rate to Health in batches, and test logs showed the newest
    /// reading is often 1 to 5 minutes old in the background, so this allows for that.
    static let maximumReadingAge: TimeInterval = 5 * 60
    /// Each check looks back this much further than the chosen window, so the batching
    /// delay above doesn't leave the end of the window empty
    static let healthWriteDelayAllowance: TimeInterval = 3 * 60
    /// Share of readings that must be elevated, so one dip at a crossing doesn't reset everything
    static let elevatedShare: Double = 0.9
    /// Too few readings say nothing about the whole window
    static let minimumReadings = 5
    /// After asking, wait this long before asking again
    static let promptCooldown: TimeInterval = 60 * 60
    /// "Not now" silences the prompt for this long
    static let notNowSnooze: TimeInterval = 2 * 60 * 60
    /// watchOS treats this as "no earlier than"; it caps apps at about 4 wakes an hour anyway
    static let refreshInterval: TimeInterval = 15 * 60
    /// Checks piggybacked on iPhone updates run at most this often. Short, because the iPhone
    /// often sends two updates a few seconds apart; a longer gap skipped real wakes in testing.
    static let phoneUpdateCheckGap: TimeInterval = 90

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
        static let nextBackgroundCheck = "Trio.exercisePrompt.nextBackgroundCheck"
        static let lastPhoneUpdateCheck = "Trio.exercisePrompt.lastPhoneUpdateCheck"
        static let snoozedUntil = "Trio.exercisePrompt.snoozedUntil"
        static let isEnabled = "Trio.exercisePrompt.isEnabled"
        static let thresholdBPM = "Trio.exercisePrompt.thresholdBPM"
        static let minutes = "Trio.exercisePrompt.minutes"
    }

    /// The user's settings, stored on the watch so background checks have them without the phone
    struct Config {
        /// Readings at or above this count as elevated
        let thresholdBPM: Double
        /// How long heart rate has to stay elevated; also how far back each check looks
        let minutes: Double

        var window: TimeInterval { minutes * 60 }
        var minimumCoverage: TimeInterval { window * ExerciseHeartRateMonitor.minimumCoverageShare }
    }

    private let healthStore = HKHealthStore()
    private let heartRateType = HKQuantityType(.heartRate)
    private let defaults = UserDefaults.standard
    private let log = WatchLogger.shared

    private init() {}

    // MARK: - Entry points

    var config: Config {
        let threshold = defaults.object(forKey: DefaultsKey.thresholdBPM) as? Double ?? Self.defaultThresholdBPM
        let minutes = defaults.object(forKey: DefaultsKey.minutes) as? Double ?? Self.defaultMinutes
        return Config(
            thresholdBPM: threshold.clamped(to: Self.thresholdRange),
            minutes: minutes.clamped(to: Self.minutesRange)
        )
    }

    /// Called with the threshold and duration the iPhone sends in every watch state update.
    func setConfig(thresholdBPM: Double?, minutes: Double?) {
        let current = config
        if let thresholdBPM, thresholdBPM != current.thresholdBPM {
            defaults.set(thresholdBPM.clamped(to: Self.thresholdRange), forKey: DefaultsKey.thresholdBPM)
            log.info(.exercise, "Threshold set to \(Int(thresholdBPM)) bpm")
        }
        if let minutes, minutes != current.minutes {
            defaults.set(minutes.clamped(to: Self.minutesRange), forKey: DefaultsKey.minutes)
            log.info(.exercise, "Duration set to \(Int(minutes)) min")
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
            // Health access can only be requested while the app is open
            if appIsActive { appDidBecomeActive() }
        } else {
            UNUserNotificationCenter.current()
                .removeDeliveredNotifications(withIdentifiers: [PromptNotification.requestIdentifier])
        }
    }

    /// Call when the app becomes active: asks for permissions once, checks right away,
    /// and makes sure a background check is scheduled. Does nothing while the setting is off.
    func appDidBecomeActive() {
        guard isEnabled else { return }
        Task {
            await requestPermissionsIfNeeded()
            await check(reason: "app opened")
            // Only fill a gap: rescheduling here would push a pending check back 15 minutes
            // every time the app is opened
            await scheduleNextBackgroundCheck(onlyIfNonePending: true)
        }
    }

    /// Runs from the SwiftUI `.backgroundTask(.appRefresh)` handler.
    func handleBackgroundRefresh() async {
        // Turned off since this was scheduled: don't read and don't schedule another
        guard isEnabled else { return }
        await check(reason: "background refresh")
        await scheduleNextBackgroundCheck()
    }

    /// Trio's iPhone sends a state update after every loop (about every 5 minutes), and
    /// watchOS may wake the watch app in the background to receive it. This piggybacks a
    /// check on those wakes, so the prompt can come sooner than the 15-minute refreshes allow.
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

        Task { await check(reason: "phone update") }
    }

    /// "Not now" on the notification.
    func snooze() {
        let until = Date().addingTimeInterval(Self.notNowSnooze)
        defaults.set(until, forKey: DefaultsKey.snoozedUntil)
        log.info(.exercise, "Prompt snoozed until \(until.formatted(date: .omitted, time: .shortened))")
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

    private func check(reason: String) async {
        guard isEnabled else { return }
        let now = Date()
        let config = self.config

        if let snoozedUntil = defaults.object(forKey: DefaultsKey.snoozedUntil) as? Date, snoozedUntil > now {
            log.debug(.exercise, "Check (\(reason)) skipped: snoozed")
            return
        }
        if let lastPrompt = defaults.object(forKey: DefaultsKey.lastPromptDate) as? Date,
           now.timeIntervalSince(lastPrompt) < Self.promptCooldown
        {
            log.debug(.exercise, "Check (\(reason)) skipped: asked within the last hour")
            return
        }

        let readings: [Reading]
        do {
            readings = try await fetchReadings(
                since: now.addingTimeInterval(-(config.window + Self.healthWriteDelayAllowance))
            )
        } catch {
            // errorDatabaseInaccessible means the watch is locked (off the wrist)
            log.warning(.exercise, "Check (\(reason)) could not read heart rate", error: error)
            return
        }

        let result = Self.evaluate(readings, now: now, config: config)
        log.info(.exercise, "Check (\(reason)): \(result.summary)")

        guard result.isElevated else { return }
        await postPrompt(config: config)
    }

    struct Reading {
        let start: Date
        let end: Date
        let bpm: Double
        /// A series sample stands for several readings
        let count: Int
    }

    struct Evaluation {
        let isElevated: Bool
        let summary: String
    }

    /// Pure so it can be tuned from the logs without touching HealthKit.
    static func evaluate(_ readings: [Reading], now: Date, config: Config) -> Evaluation {
        let total = readings.reduce(0) { $0 + $1.count }
        guard total >= minimumReadings, let first = readings.first, let last = readings.last else {
            return Evaluation(isElevated: false, summary: "\(total) readings, too few")
        }

        let elevated = readings.filter { $0.bpm >= config.thresholdBPM }.reduce(0) { $0 + $1.count }
        let share = Double(elevated) / Double(total)
        let coverage = last.end.timeIntervalSince(first.start)
        let newestAge = now.timeIntervalSince(last.end)
        let minBPM = Int(readings.map(\.bpm).min() ?? 0)
        let maxBPM = Int(readings.map(\.bpm).max() ?? 0)

        let isElevated = share >= elevatedShare && coverage >= config.minimumCoverage && newestAge <= maximumReadingAge
        let summary = "\(total) readings, \(minBPM)-\(maxBPM) bpm, \(Int(share * 100))% ≥ \(Int(config.thresholdBPM)), " +
            "covering \(Int(coverage / 60)) min, newest \(Int(newestAge))s old → \(isElevated ? "elevated" : "not elevated")"
        return Evaluation(isElevated: isElevated, summary: summary)
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

    // MARK: - Notification

    private func postPrompt(config: Config) async {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Are you exercising?", comment: "Exercise prompt title")
        content.body = String(
            localized: "Your heart rate has been above \(Int(config.thresholdBPM)) bpm for \(Int(config.minutes)) minutes. Set a temp target or override?",
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
            defaults.set(Date(), forKey: DefaultsKey.lastPromptDate)
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
        guard HKHealthStore.isHealthDataAvailable() else {
            log.warning(.exercise, "Health data is not available on this watch")
            return
        }
        do {
            let status = try await healthStore.statusForAuthorizationRequest(toShare: [], read: [heartRateType])
            if status == .shouldRequest {
                try await healthStore.requestAuthorization(toShare: [], read: [heartRateType])
                log.info(.exercise, "Asked for heart rate access")
            }
        } catch {
            log.error(.exercise, "Heart rate access request failed", error: error)
        }

        do {
            _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error(.exercise, "Notification permission request failed", error: error)
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
