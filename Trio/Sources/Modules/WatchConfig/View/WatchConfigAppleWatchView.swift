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
                        "When this is on, the Trio Watch app reads the heart rate your Apple Watch already records. If it stays at or above your threshold (default 100 bpm) for your chosen time (default 10 minutes), the watch asks \"Are you exercising?\" and lets you open temp targets or overrides. Nothing is changed unless you pick a preset."
                    )
                    Text(
                        "The watch asks for Health access the next time you open the Trio Watch app. Checks run about 4 times an hour while a Trio complication is on your active watch face, and every time you open the Trio Watch app."
                    )
                    Text("When this is off, the Trio Watch app does not read heart rate.")
                },
                headerText: String(localized: "Apple Watch Configuration")
            )

            if state.exercisePromptWatch {
                SettingInputSection(
                    decimalValue: $state.exercisePromptThreshold,
                    booleanValue: $booleanPlaceholder,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Heart Rate Threshold")
                        }
                    ),
                    units: state.units,
                    type: .decimal("exercisePromptThreshold"),
                    label: String(localized: "Heart Rate Threshold"),
                    miniHint: String(localized: "Heart rate that counts as exercising."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: 100 bpm").bold()
                        Text(
                            "The watch asks \"Are you exercising?\" when your heart rate stays at or above this value. Raise it if you get prompts when you aren't exercising, lower it if light exercise is missed."
                        )
                    },
                    headerText: String(localized: "Ask When Exercising")
                )

                SettingInputSection(
                    decimalValue: $state.exercisePromptMinutes,
                    booleanValue: $booleanPlaceholder,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Elevated For")
                        }
                    ),
                    units: state.units,
                    type: .decimal("exercisePromptMinutes"),
                    label: String(localized: "Elevated For"),
                    miniHint: String(localized: "How long heart rate stays high before the watch asks."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: 10 min").bold()
                        Text(
                            "Each check looks back this many minutes. Heart rate has to be at or above the threshold for most of that time, and still high now, before the watch asks."
                        )
                        Text(
                            "Checks run about 4 times an hour, so the prompt can come up to about 15 minutes after this time has passed. Opening the Trio Watch app checks right away."
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
