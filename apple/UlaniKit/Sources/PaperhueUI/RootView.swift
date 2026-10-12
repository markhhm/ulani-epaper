import SwiftUI
import UlaniKit

/// The whole app (Python: gui.App): calendar status, options, the four pages, push and
/// verify, technical details.
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
            .navigationTitle(Strings.appTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .alert(model.alert?.title ?? "", isPresented: alertShown, presenting: model.alert) { _ in
            Button(Strings.ok, role: .cancel) {}
        } message: { alert in
            Text(verbatim: alert.message)
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 560)
        #endif
    }

    private var statusRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(verbatim: model.deviceStatus)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(Strings.readInfo) {
                Task { await model.readInfo() }
            }
            .disabled(!model.canEdit)
        }
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(Strings.fitLabel, selection: fit) {
                #if os(macOS)
                Text(verbatim: Strings.fitCover).tag(FitMode.cover)
                Text(verbatim: Strings.fitContain).tag(FitMode.contain)
                #else
                Text(verbatim: Strings.fitCoverShort).tag(FitMode.cover)
                Text(verbatim: Strings.fitContainShort).tag(FitMode.contain)
                #endif
            }
            #if os(macOS)
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .labelsHidden()
            #else
            .pickerStyle(.segmented)
            #endif
            Toggle(Strings.dither, isOn: dither)
        }
        .disabled(!model.canEdit)
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            #if os(iOS)
            if model.isPushing {
                Label(Strings.keepAppOpen, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            #endif
            Text(verbatim: model.summary)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if model.isBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                Button(Strings.verify) {
                    Task { await model.verify() }
                }
                .disabled(!model.canVerify)
                Button(Strings.push) {
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
        DisclosureGroup(Strings.technicalInfo) {
            Text(verbatim: model.technicalLog.isEmpty ? Strings.technicalInfoEmpty
                                                      : model.technicalLog.joined(separator: "\n"))
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

    private var dither: Binding<Bool> {
        Binding(get: { model.dither }, set: { model.setDither($0) })
    }

    private var alertShown: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }
}
