import PaperhuePages
import SwiftUI
import UniformTypeIdentifiers

/// 我的牌卡 (Python: CardsWindow): the saved cards as pictures, newest first. 放到第 N 頁 under a
/// card chooses it for a card page (the next push sends it); ticked cards can be edited,
/// duplicated, deleted or exported.
@MainActor
struct CardsView: View {
    let model: PushViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var ticked: Set<String> = []
    @State private var status: Status?
    @State private var editor: CardEditorModel?
    @State private var importing = false
    @State private var exporting: CardFile?
    @State private var deleting = false
    /// The card 放到… offers to put on a page turned into a card page.
    @State private var offering: Card?

    private enum Status {
        case done(String), problem(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: strings[.cardsTitle]).font(.title2)
            Text(verbatim: strings[.cardsHelp])
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(strings[.cardNew]) { editor = CardEditorModel(card: nil, model: model) }
                Button(strings[.cardImport]) { importing = true }
            }

            ScrollView {
                if model.savedCards.isEmpty {
                    Text(verbatim: model.cardsProblem.map { strings.cardsUnreadable($0) } ?? strings[.cardsNone])
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(212), alignment: .top), count: 3), spacing: 12) {
                    ForEach(model.savedCards) { card in cell(card) }
                }
                .id(model.cardShelf.version)  // redrawn when a picture arrives
            }
            .frame(minHeight: 300)

            HStack {
                Button(strings[.cardEdit]) { one().map { editor = CardEditorModel(card: $0, model: model) } }
                Button(strings[.cardDuplicate]) {
                    if let card = one() { report(model.duplicateCard(card), done: strings[.cardDuplicated]) }
                }
                Button(strings[.cardDelete]) {
                    if chosen.isEmpty { status = .problem(strings[.cardPickOne]) } else { deleting = true }
                }
                Button(strings[.cardExport]) { export() }
                Spacer()
                Button(strings[.close]) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            switch status {
            case .done(let text): Text(verbatim: text).foregroundStyle(.secondary)
            case .problem(let text): Text(verbatim: text).foregroundStyle(.red)
            case nil: EmptyView()
            }
        }
        .padding()
        .frame(width: 700)
        .disabled(!model.canEdit)
        .onAppear { model.reloadCards() }
        .sheet(item: $editor) { editor in
            CardEditorView(editor: editor, model: model)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [CardFile.type, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                // An untrusted file: read at most a little more than a card file may hold.
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: CardStore.maxJSONBytes + CardStore.maxImageBytes + 64 * 1024) ?? Data()
                report(model.importCard(data), done: strings[.cardImported])
            } catch {
                status = .problem(strings.cardFailed(Problem(error)))
            }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: CardFile.type,
                      defaultFilename: exporting?.name) { result in
            if case .success(let url) = result {
                status = .done(strings.cardExported(url.lastPathComponent))
            } else if case .failure(let error) = result {
                status = .problem(strings.cardFailed(Problem(error)))
            }
        }
        .confirmationDialog(strings[.cardDeleteTitle], isPresented: $deleting) {
            Button(strings[.cardDelete], role: .destructive) {
                report(model.deleteCards(chosen), done: strings[.cardDeleted])
                ticked = []
            }
            Button(strings[.cancel], role: .cancel) {}
        } message: {
            Text(verbatim: strings.cardDeleteAsk(chosen.count))
        }
        .alert(strings[.cardPageTitle], isPresented: Binding(get: { offering != nil }, set: { if !$0 { offering = nil } })) {
            Button(strings[.cardPageConvert]) {
                if let card = offering, let offer = model.cardPageOffer {
                    model.setKind(.card, for: offer.page)
                    put(card, on: offer.page)
                }
            }
            Button(strings[.cancel], role: .cancel) {}
        } message: {
            if let offer = model.cardPageOffer {
                Text(verbatim: strings.cardPageAsk(page: offer.page, kind: offer.kind))
            }
        }
    }

    private var strings: Strings { model.strings }

    /// One card: its picture, a tick with the card pages it is on, and 放到第 N 頁 (放到… with
    /// several card pages, or the offer to make one).
    private func cell(_ card: Card) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack {
                Rectangle().fill(.quaternary)
                if let image = model.cardImage(card) {
                    PanelImage(image: image)
                } else {
                    Text(verbatim: model.cardPhotoUnreadable(card) ? strings[.cardUnreadable] : strings[.rendering])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 200, height: 120)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .onTapGesture(count: 2) { editor = CardEditorModel(card: card, model: model) }
            Toggle(isOn: Binding(get: { ticked.contains(card.id) },
                                 set: { if $0 { ticked.insert(card.id) } else { ticked.remove(card.id) } })) {
                Text(verbatim: strings.cardOnPages(model.pages(showing: card))).font(.caption)
            }
            let pages = model.cardPages
            if pages.count > 1 {
                Menu(strings[.cardPutMenu]) {
                    ForEach(pages, id: \.self) { page in
                        Button(strings.cardPut(page)) { put(card, on: page) }
                    }
                }
                .fixedSize()
            } else {
                Button(pages.first.map(strings.cardPut) ?? strings[.cardPutMenu]) {
                    if let page = pages.first { put(card, on: page) } else { offering = card }
                }
            }
        }
    }

    private var chosen: [Card] { model.savedCards.filter { ticked.contains($0.id) } }

    /// The one ticked card; with none or several, 請先勾選一張牌卡。
    private func one() -> Card? {
        guard chosen.count == 1 else {
            status = .problem(strings[.cardPickOne])
            return nil
        }
        return chosen[0]
    }

    private func put(_ card: Card, on page: Int) {
        model.chooseCard(card, for: page)
        status = .done(strings.cardPutDone(page))
    }

    private func export() {
        guard let card = one() else { return }
        switch model.exportCard(card) {
        case .success(let data): exporting = CardFile(data: data, name: "card-\(card.id).\(CardStore.fileExtension)")
        case .failure(let problem): status = .problem(strings.cardFailed(problem))
        }
    }

    private func report(_ problem: Problem?, done: String) {
        status = problem.map { .problem(strings.cardFailed($0)) } ?? .done(done)
    }
}

/// A .paperhue-card file for the save panel.
struct CardFile: FileDocument {
    static let type = UTType(filenameExtension: CardStore.fileExtension, conformingTo: .data) ?? .data
    static var readableContentTypes: [UTType] { [type] }

    let data: Data
    var name = ""

    init(data: Data, name: String) {
        self.data = data
        self.name = name
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
