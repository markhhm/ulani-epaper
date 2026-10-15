import SwiftUI

/// 每日排程 (Python: the schedule dialog): off until the user adds at least one time and turns
/// it on; no default times. The background agent then syncs the calendar pages at those times.
@MainActor
struct ScheduleView: View {
    let model: PushViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var times: [String] = []
    @State private var picked = Calendar.current.startOfDay(for: Date())
    @State private var problem: Problem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: strings[.scheduleTitle]).font(.title2)
            Text(verbatim: model.settings.schedule.isEmpty ? strings[.scheduleStateOff]
                                                           : strings.scheduleOn(model.settings.schedule))
                .font(.headline)
            Text(verbatim: strings[.schedulePrompt]).fixedSize(horizontal: false, vertical: true)

            HStack {
                DatePicker(strings[.scheduleAddTime], selection: $picked, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Button(strings[.scheduleAddTime]) {
                    let time = Self.time(picked)
                    if !times.contains(time) { times = (times + [time]).sorted() }
                }
            }
            List {
                ForEach(times, id: \.self) { time in
                    HStack {
                        Text(verbatim: time).monospacedDigit()
                        Spacer()
                        Button(strings[.scheduleRemoveTime]) { times.removeAll { $0 == time } }
                    }
                }
            }
            .frame(minHeight: 90)

            Text(verbatim: strings[.scheduleNote])
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.scheduleNeedsApproval {
                Text(verbatim: strings[.scheduleApproval])
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: strings.lastSync(model.lastSync))
                .font(.caption)
                .foregroundStyle(.secondary)
            if !model.settings.schedule.isEmpty {
                Text(verbatim: strings.scheduleLastRun(model.scheduleLastRun))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.scheduleLooksStuck {
                Text(verbatim: strings[.scheduleStuck])
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Text(verbatim: strings.problem(problem)).foregroundStyle(.red)
            }

            HStack {
                Button(strings[.scheduleTurnOff]) {
                    problem = model.turnScheduleOff()
                    times = []
                }
                .disabled(model.settings.schedule.isEmpty)
                Spacer()
                Button(strings[.scheduleApply]) { problem = model.setSchedule(times) }
                    .disabled(times.isEmpty)  // at least one time
                Button(strings[.done]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
        .onAppear { times = model.settings.schedule }
    }

    private var strings: Strings { model.strings }

    /// "HH:MM" of `date` in this Mac's zone.
    static func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
