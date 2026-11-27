import SwiftUI

/// Last page of the watch app while Ask to Temp Target When Exercise Detected is on: every recent exercise check,
/// newest first, so detection can be tested and tuned right on the wrist.
struct ExerciseCheckHistoryView: View {
    @State private var records: [ExerciseCheckRecord] = []
    @State private var showingAllChecks = false

    var body: some View {
        // A page in the main vertical TabView can't hold its own scrolling List: the pages and
        // the List both want the swipe and the Digital Crown. Like the alarm snooze page, this
        // page shows a summary and opens the full list in a sheet.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(spacing: 6) {
                Button {
                    showingAllChecks = true
                } label: {
                    Image(systemName: "figure.run")
                        .font(.title2)
                        .frame(width: 80, height: 80)
                        .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 2))
                }
                .buttonStyle(.plain)

                if let latest = records.first {
                    Text(latest.outcome.label)
                        .font(.footnote).bold()
                        .foregroundStyle(latest.outcome.color)
                        .multilineTextAlignment(.center)
                    Text(
                        "\(latest.date.formatted(date: .omitted, time: .shortened)) · \(records.count) checks"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                } else {
                    Text("Exercise Checks")
                        .font(.footnote).bold()
                    Text("None yet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: context.date, initial: true) {
                records = ExerciseHeartRateMonitor.shared.history
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { showingAllChecks = true }
        .sheet(isPresented: $showingAllChecks) {
            ExerciseCheckListView(records: $records)
        }
    }
}

/// Every recent check, newest first. Tap a row for the details behind its decision.
private struct ExerciseCheckListView: View {
    @Binding var records: [ExerciseCheckRecord]
    @State private var expanded: String?

    var body: some View {
        NavigationView {
            List {
                if records.isEmpty {
                    Text("No checks yet. One runs every time you open the app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(records) { record in
                    row(record)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            expanded = expanded == record.id ? nil : record.id
                        }
                }
                if !records.isEmpty {
                    Button("Clear", role: .destructive) {
                        ExerciseHeartRateMonitor.shared.clearHistory()
                        records = []
                    }
                }
            }
            .navigationTitle("Exercise Checks")
        }
    }

    private func row(_ record: ExerciseCheckRecord) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(record.date.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(record.reason.shortLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(record.outcome.label)
                .font(.footnote).bold()
                .foregroundStyle(record.outcome.color)
            if let evaluation = record.evaluation {
                Text("\(evaluation.minBPM)–\(evaluation.maxBPM) bpm · \(evaluation.elevatedPercent)% ≥ \(evaluation.elevatedBPM)")
                    .font(.caption2)
                if expanded == record.id {
                    Text(
                        "\(evaluation.readingCount) readings over \(evaluation.coverageMinutes) min, newest \(evaluation.newestAgeSeconds)s old"
                    )
                    .font(.caption2)
                    if let motion = record.motion {
                        Text(
                            "Steps \(motion.steps.map(String.init) ?? "n/a") · moving \(motion.activeMinutes.map { String(Int($0)) } ?? "n/a") min"
                        )
                        .font(.caption2)
                    }
                    Text(evaluation.why)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private extension ExerciseHeartRateMonitor.CheckReason {
    var shortLabel: String {
        switch self {
        case .appOpened: return String(localized: "opened", comment: "Exercise check reason: app opened")
        case .backgroundRefresh: return String(localized: "background", comment: "Exercise check reason")
        case .phoneUpdate: return String(localized: "iPhone", comment: "Exercise check reason: iPhone update")
        }
    }
}

private extension ExerciseCheckRecord.Outcome {
    var color: Color {
        switch self {
        case .reminded,
             .wouldRemind: return .green
        case .sustainedWaiting: return .orange
        case .readFailed: return .red
        case .notSustained,
             .skippedAdjustmentActive,
             .skippedCooldown,
             .skippedSnoozed: return .primary
        }
    }
}
