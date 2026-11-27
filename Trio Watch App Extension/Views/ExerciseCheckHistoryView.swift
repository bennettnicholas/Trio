import SwiftUI

/// Last page of the watch app: the latest exercise check, with every recent check one tap away,
/// so detection can be tested and tuned right on the wrist.
struct ExerciseCheckHistoryView: View {
    let isEnabled: Bool

    @State private var records: [ExerciseCheckRecord] = []
    @State private var showingAllChecks = false

    var body: some View {
        // Kept as plain as the alarm snooze page: no scrolling list or timer inside the main
        // vertical pages, which both drive the Digital Crown. The full list opens in a sheet.
        VStack(spacing: 6) {
            Button {
                records = ExerciseHeartRateMonitor.shared.history
                showingAllChecks = true
            } label: {
                Image(systemName: "figure.run")
                    .font(.title2)
                    .frame(width: 80, height: 80)
                    .overlay(Circle().stroke(Color.primary.opacity(0.4), lineWidth: 2))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Exercise Checks"))

            if !isEnabled {
                Text("Exercise reminder is off")
                    .font(.footnote).bold()
                Text("Turn it on in Trio on iPhone")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let latest = records.first {
                Text(latest.outcome.label)
                    .font(.footnote).bold()
                    .foregroundStyle(latest.outcome.color)
                    .multilineTextAlignment(.center)
                Text("\(latest.date.formatted(date: .omitted, time: .shortened)) · \(records.count) checks")
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
        // Reload each time the page comes into view
        .onAppear { records = ExerciseHeartRateMonitor.shared.history }
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
