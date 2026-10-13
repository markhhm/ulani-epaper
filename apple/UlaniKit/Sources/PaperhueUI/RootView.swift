import SwiftUI
import UniformTypeIdentifiers
import UlaniKit

/// The whole app (Python: gui.App): device status, the calendar row, options, the four pages,
/// push, and the language toggle in the toolbar. Every text comes from the model's current
/// `Strings`, so the toggle switches them all at once.
@MainActor
public struct RootView: View {
    /// The dialogs of the calendar row.
    private enum Sheet: String, Identifiable {
        case feeds, notes, schedule
        var id: String { rawValue }
    }

    @State private var model: PushViewModel
    @State private var sheet: Sheet?
    /// Photos dropped on the window that need some pages turned into photo pages first.
    @State private var pendingDrop: [URL] = []

    /// The app talking to the real calendar over Bluetooth; every window shares one model
    /// (`PushViewModel.shared`), so two windows never use the calendar at once.
    public init() {
        _model = State(initialValue: PushViewModel.shared)
    }

    public init(model: PushViewModel) {
        _model = State(initialValue: model)
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.menusSwitchAtNextLaunch {
                        Text(verbatim: strings[.menusNextLaunch])
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    statusRow
                    calendarRow
                    options
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                        GridItem(.flexible(), spacing: 12, alignment: .top)],
                              spacing: 12) {
                        ForEach(model.pages) { page in
                            PageTileView(page: page, model: model, openNotes: { sheet = .notes })
                        }
                    }
                }
                .padding()
            }
            // Photos dropped on the window fill the photo pages (a tile takes a photo dropped on it).
            .dropDestination(for: URL.self) { urls, _ in
                let photos = urls.filter(isImage)
                guard !photos.isEmpty, model.canEdit else { return false }
                if model.dropConversion(count: photos.count).isEmpty {
                    model.loadDropped(photos, convert: false)
                } else {
                    pendingDrop = photos  // asks first (照片比照片頁多)
                }
                return true
            }
            // Pinned below the pages: a short window clips the pages, never the push button.
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle(strings[.appTitle])
            .toolbar {
                ToolbarItem(placement: .primaryAction) { languageToggle }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .feeds: FeedsView(model: model)
            case .notes: NotesView(model: model)
            case .schedule: ScheduleView(model: model)
            }
        }
        .alert(strings[.dropTitle], isPresented: Binding(get: { !pendingDrop.isEmpty },
                                                          set: { if !$0 { pendingDrop = [] } })) {
            Button(strings[.dropConvert]) { model.loadDropped(pendingDrop, convert: true) }
            Button(strings[.dropKeep], role: .cancel) { model.loadDropped(pendingDrop, convert: false) }
        } message: {
            Text(verbatim: strings.dropAsk(photos: pendingDrop.count, slots: model.pages.filter { $0.kind == .photo }.count,
                                           convert: model.dropConversion(count: pendingDrop.count)))
        }
        .alert(model.alertTitle ?? "", isPresented: alertShown, presenting: model.alert) { _ in
            Button(strings[.ok], role: .cancel) {}
        } message: { alert in
            Text(verbatim: strings.alertMessage(alert))
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    private var strings: Strings { model.strings }

    /// Named after the language it switches to ("English" / "中文"); usable at any time,
    /// also during a job. macOS keeps the menu bar in the launch language, so after a switch
    /// a line at the top says it follows at the next launch.
    private var languageToggle: some View {
        Button(model.language.toggleLabel) {
            model.toggleLanguage()
        }
        .help(strings[.languageToggleHint])
        .accessibilityHint(Text(verbatim: strings[.languageToggleHint]))
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: model.deviceStatusText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(strings[.readInfo]) {
                Task { await model.readInfo() }
            }
            .disabled(!model.canEdit)
        }
    }

    /// The calendar sources, notes, 立即同步 and the daily schedule. Editing only saves;
    /// 立即同步 sends the calendar pages.
    private var calendarRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: strings.feedsLine(model.settings.feeds))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: strings.lastSync(model.lastSync))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button(strings[.feedsButton]) { sheet = .feeds }
                Button(strings[.notesButton]) { sheet = .notes }
                Button(strings[.scheduleButton]) { sheet = .schedule }
                Spacer()
                Button(strings[.syncButton]) {
                    Task { await model.syncNow() }
                }
                .disabled(!model.canSync)
            }
            .disabled(!model.canEdit)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(strings[.fitLabel], selection: fit) {
                Text(verbatim: strings[.fitCover]).tag(FitMode.cover)
                Text(verbatim: strings[.fitContain]).tag(FitMode.contain)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            Picker(strings[.grainLabel], selection: grain) {
                ForEach(Grain.allCases, id: \.self) { level in
                    Text(verbatim: strings.grain(level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .fixedSize()
        }
        .disabled(!model.canEdit)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: model.summaryText)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if let loaded = model.partialDrop {
                Text(verbatim: strings.dropPartial(loaded))
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if !model.lostBackgrounds.isEmpty {
                Text(verbatim: strings.lostBackgrounds(model.lostBackgrounds))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(model.skipped, id: \.pages) { skipped in
                Text(verbatim: strings.skipped(skipped))
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(strings[.push]) {
                    Task { await model.push() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canPush)
            }
        }
        .padding()
        .background(.bar)
    }

    // MARK: bindings

    private var fit: Binding<FitMode> {
        Binding(get: { model.fit }, set: { model.setFit($0) })
    }

    private var grain: Binding<Grain> {
        Binding(get: { model.grain }, set: { model.setGrain($0) })
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }
}

/// An image file, by its extension (what a photo picker would accept).
func isImage(_ url: URL) -> Bool {
    UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
}
