import PaperhueAgenda
import SwiftUI

/// 留言 (Python: NotesDialog): write, delete and clear notes. Only saves them on this Mac and
/// redraws the board previews; they reach the device with the next push.
@MainActor
struct NotesView: View {
    let model: PushViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var colour = NoteColour.yellow
    @State private var problem: Problem?
    /// What the last change did (已新增留言。 and the like).
    @State private var done: Strings.Key?
    @State private var selection: String?
    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: strings[.notesTitle]).font(.title2)
            if !model.hasBoardPage {
                Text(verbatim: strings[.notesNoBoard])
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(verbatim: strings[.notesIntro])
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: strings.notesTextLabel())
            TextEditor(text: $text)
                .font(.body)
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .accessibilityLabel(Text(verbatim: strings.notesTextLabel()))
            HStack {
                Picker(strings[.feedColour], selection: $colour) {
                    ForEach(NoteColour.allCases, id: \.self) { colour in
                        Text(verbatim: strings.noteColour(colour)).tag(colour)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                Text(verbatim: strings.noteCount(text))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button(strings[.notesAdd]) { add() }
                    .disabled(Note.normalize(text).isEmpty)
            }
            if let problem {
                Text(verbatim: strings.problem(problem))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let done {
                Text(verbatim: strings[done]).foregroundStyle(.secondary)
            }

            Text(verbatim: strings[.notesListTitle])
            List(selection: $selection) {
                ForEach(model.notes) { note in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(Self.colour(note.color)).frame(width: 10, height: 10)
                        Text(verbatim: Self.when(note)).monospacedDigit().foregroundStyle(.secondary)
                        Text(verbatim: note.text).lineLimit(2)
                    }
                    .tag(note.id)
                }
            }
            .frame(minHeight: 150)
            .overlay {
                if model.notes.isEmpty {
                    Text(verbatim: model.notesProblem.map(strings.problem) ?? strings[.notesEmpty])
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button(strings[.notesDelete]) { delete() }
                    .disabled(selection == nil)
                Button(strings[.notesClear]) { confirmingClear = true }
                    .disabled(model.notes.isEmpty)
                Spacer()
                Button(strings[.done]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 540)
        .disabled(!model.canEdit)
        .confirmationDialog(strings.notesClearAsk(model.notes.count), isPresented: $confirmingClear) {
            Button(strings[.notesClearConfirm], role: .destructive) {
                problem = model.clearNotes()
                done = problem == nil ? .notesCleared : nil
            }
            Button(strings[.cancel], role: .cancel) {}
        }
    }

    private var strings: Strings { model.strings }

    private func add() {
        problem = model.addNote(text, color: colour.rawValue)
        done = problem == nil ? .notesAdded : nil
        if problem == nil { text = "" }
    }

    private func delete() {
        guard let selection else { return }
        problem = model.removeNote(id: selection)
        done = problem == nil ? .notesDeleted : nil
        self.selection = nil
    }

    /// "10/12 14:03" in this Mac's zone (Python: notes.when).
    static func when(_ note: Note) -> String {
        guard let time = note.time(in: .current) else { return "" }
        return "\(time.date.month)/\(time.date.day) " + String(format: "%02d:%02d", time.hour, time.minute)
    }

    static func colour(_ name: String) -> Color {
        switch NoteColour(rawValue: name) {
        case .orange: .orange
        case .green: .green
        case .blue: .blue
        case .red: .red
        default: .yellow
        }
    }
}
