import PaperhuePages
import PhotosUI
import SwiftUI

/// The card editor (Python: CardEditor): the card at 3/4 size as the device will show it, a frame
/// around each text box (the selected one with corner handles: drag inside to move it, a corner
/// to resize it), and the background and text box controls beside it.
@MainActor
struct CardEditorView: View {
    let editor: CardEditorModel
    let model: PushViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var choosingPhoto = false
    @State private var pickedItem: PhotosPickerItem?
    @State private var importingFile = false
    @State private var cropEditing: CropEditing?
    /// What the running drag holds: a corner of the selected box, or the box itself.
    @State private var grab: Grab?
    @State private var last = CGPoint.zero
    /// The pointer is over the preview: the mouse wheel changes the selected box's size.
    @State private var hovering = false
    @State private var wheel: Any?

    private enum Grab: Equatable {
        case move
        case corner(CardEditorModel.Corner)
    }

    /// The preview's size: 3/4 of the panel's 800 x 480 (Python: CardEditor.SCALE).
    private static let view = CGSize(width: 600, height: 360)
    private static let handle: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(verbatim: strings[editor.isNew ? .cardEditorNew : .cardEditorEdit]).font(.title2)
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    canvas
                    Text(verbatim: strings[.cardHelp])
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                controls.frame(width: 260)
            }
            if let status = statusText {
                Text(verbatim: status.text).foregroundStyle(status.error ? .red : .secondary)
            }
            HStack {
                Spacer()
                Button(strings[.cancel], role: .cancel) {
                    editor.close()
                    dismiss()
                }
                Button(strings[.cardSave]) {
                    if editor.save() {
                        editor.close()
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .photosPicker(isPresented: $choosingPhoto, selection: $pickedItem, matching: .images,
                      preferredItemEncoding: .current)
        .onChange(of: pickedItem) { _, item in
            guard let item else { return }
            pickedItem = nil
            editor.choosePhoto(.libraryItem(item))
        }
        .fileImporter(isPresented: $importingFile, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { editor.choosePhoto(.file(url)) }
        }
        .sheet(item: $cropEditing) { editing in
            CropEditorView(editing: editing, model: model)
        }
        .onAppear {
            // The mouse wheel over the preview: 4 px larger or smaller per step (Python: <MouseWheel>).
            wheel = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
                guard hovering, let size = editor.box?.size, event.scrollingDeltaY != 0 else { return event }
                editor.setSize(size + (event.scrollingDeltaY > 0 ? 4 : -4))
                return nil
            }
        }
        .onDisappear {
            if let wheel { NSEvent.removeMonitor(wheel) }
        }
    }

    private var strings: Strings { model.strings }

    // MARK: the preview

    private var canvas: some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.quaternary)
            if let preview = editor.preview {
                Image(decorative: preview, scale: 1).resizable().interpolation(.medium)
            }
            ForEach(Array(editor.texts.enumerated()), id: \.offset) { index, text in
                frame(text.box, selected: index == editor.current)
            }
        }
        .frame(width: Self.view.width, height: Self.view.height)
        .clipped()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .gesture(DragGesture(minimumDistance: 0).onChanged(drag).onEnded { _ in
            if grab != nil { editor.finishDrag() }
            grab = nil
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: strings[editor.isNew ? .cardEditorNew : .cardEditorEdit]))
    }

    /// A text box's frame: the selected one blue with a handle on each corner, the others dashed.
    private func frame(_ box: CardText.Box, selected: Bool) -> some View {
        let rect = Self.onCanvas(box)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(selected ? Color.accentColor : .gray,
                              style: StrokeStyle(lineWidth: 1, dash: selected ? [] : [3, 3]))
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
            if selected {
                ForEach(CardEditorModel.Corner.allCases, id: \.self) { corner in
                    let point = Self.point(corner, rect)
                    Rectangle()
                        .fill(.white)
                        .overlay(Rectangle().strokeBorder(Color.accentColor))
                        .frame(width: Self.handle, height: Self.handle)
                        .offset(x: point.x - Self.handle / 2, y: point.y - Self.handle / 2)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func drag(_ value: DragGesture.Value) {
        let location = value.location
        if grab == nil {
            last = value.startLocation
            if let box = editor.box, let corner = CardEditorModel.Corner.allCases.first(where: {
                let point = Self.point($0, Self.onCanvas(box.box))
                return abs(point.x - last.x) <= Self.handle && abs(point.y - last.y) <= Self.handle
            }) {
                grab = .corner(corner)
            } else {
                let x = last.x / Self.view.width, y = last.y / Self.view.height
                let hit = editor.texts.indices.reversed().first { i in
                    let b = editor.texts[i].box
                    return b.x <= x && x <= b.x + b.width && b.y <= y && y <= b.y + b.height
                }
                if let hit, hit != editor.current { editor.select(hit) }
                grab = hit == nil ? nil : .move
            }
        }
        switch grab {
        case .move:
            editor.move(dx: (location.x - last.x) / Self.view.width, dy: (location.y - last.y) / Self.view.height,
                        preview: false)
            last = location
        case .corner(let corner):
            editor.dragCorner(corner, x: location.x / Self.view.width, y: location.y / Self.view.height, preview: false)
        case nil:
            break
        }
    }

    private static func onCanvas(_ box: CardText.Box) -> CGRect {
        CGRect(x: box.x * view.width, y: box.y * view.height, width: box.width * view.width,
               height: box.height * view.height)
    }

    private static func point(_ corner: CardEditorModel.Corner, _ rect: CGRect) -> CGPoint {
        switch corner {
        case .nw: CGPoint(x: rect.minX, y: rect.minY)
        case .ne: CGPoint(x: rect.maxX, y: rect.minY)
        case .sw: CGPoint(x: rect.minX, y: rect.maxY)
        case .se: CGPoint(x: rect.maxX, y: rect.maxY)
        }
    }

    // MARK: the controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(strings[.cardBackground], selection: background) {
                ForEach(PanelColour.allCases, id: \.self) { ink in
                    Text(verbatim: strings.ink(ink)).tag(PanelColour?.some(ink))
                }
                if editor.hasPhoto {
                    Text(verbatim: strings[.cardBgPhoto]).tag(PanelColour?.none)
                }
            }
            HStack {
                Menu(strings[.cardPhotoButton]) {
                    Button(strings[.choosePhoto]) { choosingPhoto = true }
                    Button(strings[.chooseFile]) { importingFile = true }
                }
                .fixedSize()
                Button(strings[.adjustCrop]) { cropEditing = editor.cropEditing }
                    .disabled(!editor.hasPhoto)
            }
            Divider()
            HStack {
                Button(strings[.cardAddText]) { editor.addText(strings[.cardNewText]) }
                Button(strings[.cardDeleteText]) { editor.deleteText() }
                    .disabled(editor.box == nil)
            }
            Group {
                Text(verbatim: strings.cardTextLabel())
                TextEditor(text: Binding(get: { editor.box?.text ?? "" }, set: { editor.setText($0) }))
                    .font(.body)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                Stepper(value: Binding(get: { editor.box?.size ?? 64 }, set: { editor.setSize($0) }),
                        in: CardText.sizes, step: 4) {
                    Text(verbatim: "\(strings[.cardSize]) \(editor.box?.size ?? 0)")
                }
                Picker(strings[.cardInk], selection: Binding(get: { editor.box?.color ?? .black },
                                                            set: { editor.setInk($0) })) {
                    ForEach(PanelColour.allCases, id: \.self) { ink in
                        Text(verbatim: strings.ink(ink)).tag(ink)
                    }
                }
                Toggle(strings[.cardOutline], isOn: Binding(get: { editor.box?.outline ?? false },
                                                            set: { editor.setOutline($0) }))
                Picker(strings[.cardAlign], selection: Binding(get: { editor.box?.align ?? .center },
                                                              set: { editor.setAlign($0) })) {
                    ForEach(CardText.Align.allCases, id: \.self) { align in
                        Text(verbatim: strings.align(align)).tag(align)
                    }
                }
                .pickerStyle(.segmented)
            }
            .disabled(editor.box == nil)
        }
    }

    /// The background: one of the 7 colours, or (nil) the photo.
    private var background: Binding<PanelColour?> {
        Binding(get: { editor.hasPhoto ? nil : editor.colour },
                set: { if let ink = $0 { editor.setColour(ink) } })
    }

    private var statusText: (text: String, error: Bool)? {
        switch editor.status {
        case .none: nil
        case .makingPreview: (strings[.rendering], false)
        case .previewReady: (strings[.previewReady], false)
        case .problem(let problem): (strings.problem(problem), true)
        case .textsFull: (strings.cardTextsFull(), true)
        case .textEmpty(let n): (strings.cardTextEmpty(n), true)
        case .textTooLong(let n, let count): (strings.cardTextTooLong(n, count: count), true)
        case .saveFailed(let problem): (strings.cardSaveFailed(problem), true)
        }
    }
}
