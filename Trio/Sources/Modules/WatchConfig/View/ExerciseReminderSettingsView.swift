import SwiftUI
import Swinject

extension WatchConfig {
    /// Settings → Notifications → Exercise Reminder: turns the Apple Watch exercise reminder on,
    /// sets the user's exercise heart rate, and sets how it re-alerts until acknowledged.
    struct ExerciseReminderRootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var booleanPlaceholder: Bool = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        /// Opens the help sheet for a row
        private func hintBinding(_ label: String) -> Binding<(any View)?> {
            Binding(
                get: { selectedVerboseHint },
                set: {
                    selectedVerboseHint = $0.map { AnyView($0) }
                    hintLabel = label
                }
            )
        }

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.exercisePromptWatch,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: hintBinding(String(localized: "Ask to Temp Target When Exercise Detected")),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Ask to Temp Target When Exercise Detected"),
                    miniHint: String(localized: "Apple Watch reminds you to set a temp target when you exercise."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "When this is on, the Trio Watch app uses the heart rate, steps and motion your Apple Watch already records. When your heart rate has stayed near your exercise heart rate for about 15 minutes, the watch asks \"Are you exercising?\" and lets you open temp targets or overrides. Nothing is changed unless you pick one."
                        )
                        Text(
                            "To avoid false alarms from a minute of walking around, the watch waits for a second check about 5 minutes later, unless your steps or motion already show clear activity. Expect the reminder roughly 15 to 25 minutes in. It works for any activity, including ones with few steps like hockey."
                        )
                        Text(
                            "The watch asks for Health and Motion access the next time you open the Trio Watch app. Checks run about 4 times an hour while a Trio complication is on your active watch face, when Trio's iPhone updates reach the watch, and every time you open the Trio Watch app. No workout session runs, so battery use stays very low."
                        )
                        Text("When this is off, the Trio Watch app does not read heart rate or motion.")
                    },
                    headerText: String(localized: "Apple Watch")
                )

                if state.exercisePromptWatch {
                    SettingInputSection(
                        decimalValue: $state.exercisePromptHeartRate,
                        booleanValue: $booleanPlaceholder,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: hintBinding(String(localized: "Exercise Heart Rate")),
                        units: state.units,
                        type: .decimal("exercisePromptHeartRate"),
                        label: String(localized: "Exercise Heart Rate"),
                        miniHint: String(localized: "Your average heart rate while exercising."),
                        verboseHint: VStack(alignment: .leading, spacing: 10) {
                            Text("Default: 105 bpm").bold()
                            Text(
                                "Set this to your typical heart rate during exercise. A brisk walk puts an average adult at about 100 to 110 bpm."
                            )
                            Text(
                                "Readings count as exercising at 90% of this value, because an average includes the slower moments. Raise it if you get reminders when you aren't exercising, lower it if exercise is missed."
                            )
                        },
                        headerText: String(localized: "Detection")
                    )

                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.exercisePromptRepeat,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: hintBinding(String(localized: "Re-Alert If Not Acknowledged")),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Re-Alert If Not Acknowledged"),
                        miniHint: String(localized: "Repeat the reminder until you respond to it."),
                        verboseHint: VStack(alignment: .leading, spacing: 10) {
                            Text("Default: ON").bold()
                            Text(
                                "The reminder repeats on your Apple Watch and iPhone until you tap it, swipe it away, or pick Not now on either device."
                            )
                            Text("Repeats also stop as soon as a temp target or override is running.")
                        },
                        headerText: String(localized: "Alert")
                    )

                    if state.exercisePromptRepeat {
                        SettingInputSection(
                            decimalValue: $state.exercisePromptRepeatMinutes,
                            booleanValue: $booleanPlaceholder,
                            shouldDisplayHint: $shouldDisplayHint,
                            selectedVerboseHint: hintBinding(String(localized: "Re-Alert Every")),
                            units: state.units,
                            type: .decimal("exercisePromptRepeatMinutes"),
                            label: String(localized: "Re-Alert Every"),
                            miniHint: String(localized: "Time between repeats."),
                            verboseHint: VStack(alignment: .leading, spacing: 10) {
                                Text("Default: 10 min").bold()
                                Text("How long to wait before repeating a reminder you haven't responded to.")
                            }
                        )

                        SettingInputSection(
                            decimalValue: $state.exercisePromptRepeatCount,
                            booleanValue: $booleanPlaceholder,
                            shouldDisplayHint: $shouldDisplayHint,
                            selectedVerboseHint: hintBinding(String(localized: "Re-Alert Up To")),
                            units: state.units,
                            type: .decimal("exercisePromptRepeatCount"),
                            label: String(localized: "Re-Alert Up To"),
                            miniHint: String(localized: "Most repeats for one reminder."),
                            verboseHint: VStack(alignment: .leading, spacing: 10) {
                                Text("Default: 2 times").bold()
                                Text(
                                    "After this many repeats, the reminder stays in Notification Center and stops alerting. The watch won't remind you again for an hour."
                                )
                            }
                        )
                    }

                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.exercisePromptLogOnly,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: hintBinding(String(localized: "Log Only (Testing)")),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Log Only (Testing)"),
                        miniHint: String(localized: "Record checks without sending reminders."),
                        verboseHint: VStack(alignment: .leading, spacing: 10) {
                            Text("Default: OFF").bold()
                            Text(
                                "The watch runs every check as normal but never sends the reminder. Use this to see how the detection behaves before relying on it."
                            )
                            Text(
                                "Every check shows on the Exercise Checks page of the Trio Watch app (swipe to the last page), and is written to the watch logs you can share from Settings."
                            )
                        },
                        headerText: String(localized: "Testing")
                    )
                }
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .onAppear(perform: configureView)
            .navigationTitle("Exercise Reminder")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
        }
    }
}
