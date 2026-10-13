import PhotosUI
import SwiftUI
import UlaniKit
import UniformTypeIdentifiers

/// One page: 7-colour preview (5:3, like the panel), photo pickers, clear, the crop editor,
/// 「在裝置上顯示」, progress, status.
@MainActor
struct PageTileView: View {
    let page: PageModel
    let model: PushViewModel

    @State private var choosingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var cropEditing: CropEditing?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                preview

                Text(verbatim: page.name ?? " ")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                buttons
                    .controlSize(.small)
                    .disabled(!model.canEdit)

                ProgressView(value: Double(page.percent), total: 100)
                    .accessibilityLabel(Text(verbatim: strings.pageProgress(page.page)))

                Text(verbatim: status.isEmpty ? " " : status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Text(verbatim: strings.pageTitle(page.page))
        }
        .photosPicker(isPresented: $choosingPhoto, selection: $pickedItem, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil  // choosing the same photo again must work too
            model.load(.libraryItem(item), into: page.page)
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result {
                model.load(.file(url), into: page.page)
            }
        }
        .sheet(item: $cropEditing) { editing in
            CropEditorView(editing: editing, model: model)
        }
    }

    private var strings: Strings { model.strings }
    private var status: String { model.statusText(of: page) }
    private var canAdjustCrop: Bool { model.canAdjustCrop(page) }

    /// Click: choose a photo; double-click: adjust the crop, when it can be.
    private var preview: some View {
        TilePreview(image: page.preview, placeholder: strings[page.failed ? .unreadable : .noPhoto],
                    rendering: page.isRendering)
            .modifier(PreviewClicks(doubleClicks: canAdjustCrop, click: { choosePhoto() },
                                    doubleClick: { adjustCrop() }))
            .disabled(!model.canEdit)
            .help(canAdjustCrop ? strings[.previewHelp] : "")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(verbatim: strings.choosePhotoLabel(page: page.page)))
            .accessibilityAction { choosePhoto() }
            .accessibilityActions {
                if canAdjustCrop {
                    Button(strings[.adjustCrop]) { adjustCrop() }
                }
            }
    }

    private func choosePhoto() {
        guard model.canEdit else { return }
        choosingPhoto = true
    }

    /// Opens the crop editor at the page's crop (only while `canAdjustCrop`).
    private func adjustCrop() {
        guard let geometry = model.cropGeometry(for: page.page), let image = page.photoImage else { return }
        cropEditing = CropEditing(page: page.page, image: image, geometry: geometry)
    }

    /// Side by side when they fit, 「調整範圍…」 and 「在裝置上顯示」 on a line of their own, or
    /// all stacked in a narrow window.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                photoButtons
                pageButtons
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) { photoButtons }
                HStack(spacing: 8) { pageButtons }
            }
            VStack(alignment: .leading, spacing: 6) {
                photoButtons
                pageButtons
            }
        }
    }

    @ViewBuilder private var photoButtons: some View {
        Button(strings[.choosePhoto]) { choosingPhoto = true }
        Button(strings[.chooseFile]) { importingFile = true }
        Button(strings[.clear]) { model.clear(page: page.page) }
            .disabled(!page.hasPhoto && !page.failed)
    }

    @ViewBuilder private var pageButtons: some View {
        Button(strings[.adjustCrop]) { adjustCrop() }
            .disabled(!canAdjustCrop)
            .help(strings[.adjustCropHelp])
        // Uploads nothing: switches the device's screen to this page.
        Button(strings[.showOnDevice]) {
            Task { await model.display(page: page.page) }
        }
    }
}

/// A click on the preview chooses a photo. When the photo can be cropped (`doubleClicks`), a
/// double-click opens the crop editor instead (a single click then waits to see if a second
/// follows).
private struct PreviewClicks: ViewModifier {
    let doubleClicks: Bool
    let click: @MainActor () -> Void
    let doubleClick: @MainActor () -> Void

    @ViewBuilder func body(content: Content) -> some View {
        if doubleClicks {
            content
                .onTapGesture(count: 2, perform: doubleClick)
                .onTapGesture(perform: click)
        } else {
            content.onTapGesture(perform: click)
        }
    }
}

/// The preview area: the frame as the panel will show it, or a placeholder (in the current
/// language, from the tile).
struct TilePreview: View {
    let image: CGImage?
    let placeholder: String
    let rendering: Bool

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
                    .aspectRatio(contentMode: .fit)
            } else if !rendering {
                Text(verbatim: placeholder)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if rendering {
                ProgressView()
            }
        }
        .aspectRatio(CGFloat(Frame.width) / CGFloat(Frame.height), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }
}
