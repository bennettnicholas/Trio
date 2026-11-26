import SwiftUI

/// Last page of the watch app while Ask When Exercising is on: every recent exercise check,
/// newest first, so detection can be tested and tuned right on the wrist.
struct ExerciseCheckHistoryView: View {
    @State private var records: [ExerciseCheckRecord] = []
    @State private var expanded: Date?

    var body: some View {
        // Refresh while the page is open; checks can land in the background meanwhile
        TimelineView(.periodic(from: .now, by: 30)) { context in
            List {
                Section {
                    if records.isEmpty {
                        Text("No checks yet. One runs every time you open the app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        row(record)
                            .onTapGesture {
                                expanded = expanded == record.date ? nil : record.date
                            }
                    }
                } header: {
                    Text("Exercise Checks")
                } footer: {
                    if !records.isEmpty {
                        Button("Clear", role: .destructive) {
                            ExerciseHeartRateMonitor.shared.clearHistory()
                            records = []
                        }
                    }
                }
            }
            .onChange(of: context.date, initial: true) {
                records = ExerciseHeartRateMonitor.shared.history
            }
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
                if expanded == record.date {
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
             .skippedCooldown,
             .skippedSnoozed: return .primary
        }
    }
}
