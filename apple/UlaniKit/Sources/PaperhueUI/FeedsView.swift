import PaperhueAgenda
import SwiftUI

/// 行事曆來源 (Python: FeedsDialog): the iCal addresses the calendar pages are drawn from. An
/// address is a password: it is typed into a secure field, checked once, kept only in the
/// Keychain, and only its host is ever shown.
@MainActor
struct FeedsView: View {
    let model: PushViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var colour = ""
    @State private var checking = false
    @State private var result: Result<(name: String, events: Int?, tasks: Int?), Problem>?
    @State private var removing: Feed?
    /// The source the form edits; nil: the form adds one.
    @State private var editing: Feed?
    /// Each source's host as shown, read once when the list opens and once for a source added or
    /// given a new address: after an update macOS asks before Paperhue may read the Keychain, so
    /// reading it while drawing the list would ask again on every redraw.
    @State private var hosts: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: strings[.feedsTitle]).font(.title2)
            Text(verbatim: strings[.feedsIntro])
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List {
                ForEach(model.settings.feeds) { feed in
                    HStack {
                        Text(verbatim: feed.name)
                        Text(verbatim: hosts[feed.id] ?? "").foregroundStyle(.secondary)
                        Text(verbatim: strings.feedColour(feed.color)).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(strings[.feedEdit]) { startEditing(feed) }
                        Button(strings[.feedRemove]) { removing = feed }
                    }
                }
            }
            .frame(minHeight: 100)
            .overlay {
                if model.settings.feeds.isEmpty {
                    Text(verbatim: strings[.feedsEmpty]).foregroundStyle(.secondary).padding()
                }
            }

            Form {
                TextField(strings[.feedName], text: $name, prompt: Text(verbatim: strings[.feedNamePrompt]))
                SecureField(strings[editing == nil ? .feedAddress : .feedAddressKeep], text: $address,
                            prompt: Text(verbatim: "https://…  webcal://…"))
                TextField(strings[.feedUser], text: $user)
                SecureField(strings[editing == nil ? .feedPassword : .feedPasswordKeep], text: $password)
                Picker(strings[.feedColour], selection: $colour) {
                    ForEach([""] + Feed.colours, id: \.self) { name in
                        Text(verbatim: strings.feedColour(name)).tag(name)
                    }
                }
            }
            .disabled(checking)

            HStack {
                if checking {
                    ProgressView().controlSize(.small)
                    Text(verbatim: strings[.feedChecking])
                } else if let result {
                    switch result {
                    case .success(let saved):
                        Text(verbatim: strings.feedSaved(name: saved.name, events: saved.events, tasks: saved.tasks))
                    case .failure(let problem):
                        Text(verbatim: strings.problem(problem)).foregroundStyle(.red)
                    }
                }
                Spacer()
                if editing != nil {
                    Button(strings[.cancel]) { clearForm() }
                    Button(strings[.feedSave]) { Task { await save() } }
                        .disabled(checking)
                } else {
                    Button(strings[.feedAdd]) { Task { await add() } }
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || checking)
                }
                Button(strings[.done]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 560)
        .disabled(!model.canEdit)
        .onChange(of: model.settings.feeds, initial: true) { readHosts() }
        .confirmationDialog(removing.map { strings.feedRemoveAsk($0.name) } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(strings[.feedRemove], role: .destructive) {
                guard let feed = removing else { return }
                if feed.id == editing?.id { clearForm() }
                if let problem = model.removeFeed(feed) { result = .failure(problem) }
            }
            Button(strings[.cancel], role: .cancel) {}
        }
    }

    private var strings: Strings { model.strings }

    private func add() async {
        checking = true
        result = nil
        let outcome = await model.addFeed(name: name, url: address, user: user, password: password, color: colour)
        checking = false
        result = outcome.map { ($0.name, $0.events, $0.tasks) }
        if case .success = outcome { clearForm() }
    }

    /// 編輯…: the form shows the source's name and colour; the address and password stay empty
    /// (empty keeps them: they are never shown).
    private func startEditing(_ feed: Feed) {
        editing = feed
        (name, address, user, password, colour) = (feed.name, "", model.user(of: feed), "", feed.color)
        result = nil
    }

    private func save() async {
        guard let feed = editing else { return }
        checking = true
        result = nil
        let outcome = await model.editFeed(feed, name: name, url: address, user: user, password: password, color: colour)
        checking = false
        result = outcome
        if case .success = outcome {
            clearForm()
            hosts[feed.id] = nil  // its address may be new
            readHosts()
        }
    }

    /// Reads the hosts not read yet. When the Keychain refuses (the user denied macOS's question),
    /// the reason shows below the form; closing and reopening the list asks again.
    private func readHosts() {
        for feed in model.settings.feeds where hosts[feed.id] == nil {
            do {
                hosts[feed.id] = try model.host(of: feed) ?? strings[.feedAddressLost]
            } catch {
                hosts[feed.id] = ""
                result = .failure(Problem(error))
            }
        }
    }

    private func clearForm() {
        editing = nil
        (name, address, user, password, colour) = ("", "", "", "", "")
    }
}
