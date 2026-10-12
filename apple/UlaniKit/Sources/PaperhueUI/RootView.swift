import SwiftUI
import UlaniKit

/// The whole app (Python: gui.App): calendar status, options, the four pages, push and
/// verify, technical details, and the language toggle in the toolbar. Every text comes from
/// the model's current `Strings`, so the toggle switches them all at once.
@MainActor
public struct RootView: View {
    @State private var model: PushViewModel

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
                    statusRow
                    options
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                        GridItem(.flexible(), spacing: 12, alignment: .top)],
                              spacing: 12) {
                        ForEach(model.pages) { page in
                            PageTileView(page: page, model: model)
                        }
                    }
                    technicalInfo
                }
                .padding()
            }
            // Pinned below the pages: a short window clips the pages, never the push button.
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
            .navigationTitle(strings[.appTitle])
            .toolbar {
                ToolbarItem(placement: .primaryAction) { languageToggle }
            }
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
    /// also during a job.
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
            HStack {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(strings[.verify]) {
                    Task { await model.verify() }
                }
                .disabled(!model.canVerify)
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

    private var technicalInfo: some View {
        DisclosureGroup(strings[.technicalInfo]) {
            Text(verbatim: model.technicalLog.isEmpty ? strings[.technicalInfoEmpty]
                                                      : model.technicalLines.joined(separator: "\n"))
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        }
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
