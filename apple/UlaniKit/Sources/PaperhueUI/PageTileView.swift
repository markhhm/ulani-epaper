import PhotosUI
import SwiftUI
import UlaniKit
import UniformTypeIdentifiers

/// One page: 7-colour preview (5:3, like the panel), photo pickers, clear, progress, status.
@MainActor
struct PageTileView: View {
    let page: PageModel
    let model: PushViewModel

    @State private var choosingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var importingFile = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    choosingPhoto = true
                } label: {
                    TilePreview(image: page.preview, placeholder: page.failed ? Strings.unreadable : Strings.noPhoto,
                                rendering: page.isRendering)
                }
                .buttonStyle(.plain)
                .disabled(!model.canEdit)
                .accessibilityLabel(Text(verbatim: "\(Strings.pageTitle(page.page)) \(Strings.choosePhoto)"))

                Text(verbatim: page.name ?? " ")
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)

                buttons
                    .controlSize(.small)
                    .disabled(!model.canEdit)

                ProgressView(value: Double(page.percent), total: 100)

                Text(verbatim: page.status.isEmpty ? " " : page.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } label: {
            Text(verbatim: Strings.pageTitle(page.page))
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
    }

    /// Side by side when they fit, stacked in a narrow window.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { buttonRow }
            VStack(alignment: .leading, spacing: 6) { buttonRow }
        }
    }

    @ViewBuilder private var buttonRow: some View {
        Button(Strings.choosePhoto) { choosingPhoto = true }
        Button(Strings.chooseFile) { importingFile = true }
        Button(Strings.clear) { model.clear(page: page.page) }
            .disabled(!page.hasPhoto && !page.failed)
    }
}

/// The preview area: the frame as the panel will show it, or a placeholder.
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
