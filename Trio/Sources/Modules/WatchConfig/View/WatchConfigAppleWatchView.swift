import SwiftUI
import Swinject

struct WatchConfigAppleWatchView: BaseView {
    let resolver: Resolver
    @ObservedObject var state: WatchConfig.StateModel

    @State private var shouldDisplayHint: Bool = false
    @State var hintDetent = PresentationDetent.large
    @State var selectedVerboseHint: AnyView?
    @State var hintLabel: String?
    @State private var decimalPlaceholder: Decimal = 0.0
    @State private var booleanPlaceholder: Bool = false

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private func onDelete(offsets: IndexSet) {
        state.devices.remove(atOffsets: offsets)
        state.deleteGarminDevice()
    }

    var body: some View {
        List {
            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.confirmBolusFaster,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Confirm Bolus Faster")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Confirm Bolus Faster"),
                miniHint: String(localized: "Reduce the number of crown rotations required for bolus confirmation."),
                verboseHint: Text(
                    "Enabling this feature lowers the number of turns on the crown dial required when confirming a bolus."
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.showForecastWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Show forecast on Watch")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Show Forecast on Watch"),
                miniHint: String(localized: "Shows forecast on the Apple Watch"),
                verboseHint: Text(
                    "Enable this feature to show the forecast on the Apple Watch"
                ),
                headerText: String(localized: "Apple Watch Configuration")
            )

            SettingInputSection(
                decimalValue: $decimalPlaceholder,
                booleanValue: $state.exercisePromptWatch,
                shouldDisplayHint: $shouldDisplayHint,
                selectedVerboseHint: Binding(
                    get: { selectedVerboseHint },
                    set: {
                        selectedVerboseHint = $0.map { AnyView($0) }
                        hintLabel = String(localized: "Ask When Exercising")
                    }
                ),
                units: state.units,
                type: .boolean,
                label: String(localized: "Ask When Exercising"),
                miniHint: String(localized: "Apple Watch asks \"Are you exercising?\" when your heart rate stays high."),
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
                headerText: String(localized: "Apple Watch Configuration")
            )

            if state.exercisePromptWatch {
                SettingInputSection(
                    decimalValue: $state.exercisePromptHeartRate,
                    booleanValue: $booleanPlaceholder,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Exercise Heart Rate")
                        }
                    ),
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
                    headerText: String(localized: "Ask When Exercising")
                )

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.exercisePromptLogOnly,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Log Only (Testing)")
                        }
                    ),
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
                    }
                )
            }

            Section(
                header: Text("Contact Image"),
                content: {
                    VStack {
                        HStack {
                            NavigationLink("Contacts Configuration") {
                                ContactImage.RootView(resolver: resolver)
                            }.foregroundStyle(Color.accentColor)
                        }
                    }
                }
            ).listRowBackground(Color.chart)
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
        .navigationTitle("Apple Watch")
        .navigationBarTitleDisplayMode(.automatic)
        .settingsHighlightScroll()
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }
}
