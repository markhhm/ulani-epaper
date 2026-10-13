import AppKit
import SwiftUI
import UlaniKit

/// What the crop editor opens with: a page's photo and the frame it starts at.
public struct CropEditing: Identifiable {
    public let id = UUID()
    let page: Int
    let image: CGImage
    let geometry: CropGeometry
    /// The crop of a calendar page's background photo, not of a photo page.
    var background = false
    /// Where 確定 sends the crop instead (a card's photo).
    var onConfirm: (@MainActor (Crop?) -> Void)?
}

/// The 「調整範圍…」 sheet (shared/CROP.md, Editor): the whole photo scaled to fit, the part
/// outside the crop dimmed, the frame with rule-of-thirds guides and corner handles. Drag
/// inside the frame to move it, a corner to resize it; pinching, scrolling, the slider and
/// the arrow keys work too. `CropGeometry` does the maths and the clamping; this view only
/// feeds it. 確定 hands the result to the view model, which renders the page again; 取消
/// changes nothing. Every text follows the language toggle.
@MainActor
struct CropEditorView: View {
    let editing: CropEditing
    let model: PushViewModel

    @State private var geometry: CropGeometry
    /// The running drag: what it started on, and the frame then.
    @State private var drag: Drag?
    /// The frame when the running pinch started.
    @State private var pinchStart: CropGeometry?
    @FocusState private var canvasFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private struct Drag {
        let hit: CropCanvas.Hit
        let start: CropGeometry
    }

    init(editing: CropEditing, model: PushViewModel) {
        self.editing = editing
        self.model = model
        _geometry = State(initialValue: editing.geometry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(verbatim: strings.cropTitle(page: editing.page))
                .font(.headline)
            canvas
                .frame(minWidth: 480, idealWidth: 680, maxWidth: .infinity,
                       minHeight: 300, idealHeight: 420, maxHeight: .infinity)
            zoomSlider
            VStack(alignment: .leading, spacing: 4) {
                if !geometry.canZoom {
                    Text(verbatim: strings[.cropNoZoom])
                }
                Text(verbatim: strings[.cropHint])
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(strings[.cropReset]) { geometry = geometry.reset() }
                    .help(strings[.cropResetHelp])
                    .disabled(geometry.isCentred)
                Spacer()
                Button(strings[.cancel], role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(strings[.confirm]) {
                    if let onConfirm = editing.onConfirm {
                        onConfirm(geometry.result)
                    } else if editing.background {
                        model.setBackgroundCrop(geometry.result, for: editing.page)
                    } else {
                        model.setCrop(geometry.result, for: editing.page)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .defaultFocus($canvasFocused, true)
        .onDisappear { NSCursor.arrow.set() }
    }

    private var strings: Strings { model.strings }

    // MARK: canvas

    private var canvas: some View {
        GeometryReader { proxy in
            let layout = CropCanvas(photo: geometry.photo, size: proxy.size)
            ZStack {
                Image(decorative: editing.image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: layout.imageFrame.width, height: layout.imageFrame.height)
                    .position(x: layout.imageFrame.midX, y: layout.imageFrame.midY)
                CropOverlay(imageFrame: layout.imageFrame, frame: layout.rect(of: geometry.crop))
            }
            .contentShape(Rectangle())
            .gesture(dragGesture(layout))
            .simultaneousGesture(pinchGesture(layout))
            .background(ScrollWheelReader { delta, precise, point in
                let factor = CropGeometry.zoomFactor(scrolled: delta, precise: precise)
                geometry = geometry.zoomed(by: factor, about: layout.fraction(at: point))
            })
            .onContinuousHover { phase in
                guard case .active(let point) = phase else { return NSCursor.arrow.set() }
                switch layout.hit(point, crop: geometry.crop) {
                case .corner: NSCursor.crosshair.set()
                case .inside, .outside: (drag == nil ? NSCursor.openHand : NSCursor.closedHand).set()
                }
            }
        }
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // Takes the arrow keys: focused when the sheet opens and when clicked, whatever
        // the keyboard navigation setting.
        .focusable(interactions: .edit)
        .focused($canvasFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            geometry = geometry.nudged(Self.direction(of: press.key), large: press.modifiers.contains(.shift))
            return .handled
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: strings[.cropFrame]))
        .accessibilityValue(Text(verbatim: strings.cropZoomValue(geometry.zoom)))
        .accessibilityHint(Text(verbatim: strings[.cropHint]))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: geometry = geometry.zoomedIn()
            case .decrement: geometry = geometry.zoomedOut()
            @unknown default: break
            }
        }
        .accessibilityActions {
            ForEach(CropGeometry.Direction.allCases, id: \.self) { direction in
                Button(strings.cropMove(direction)) { geometry = geometry.nudged(direction) }
            }
        }
    }

    /// Inside the frame: moves it; on a corner handle: resizes it. Each step starts again
    /// from the frame at the start of the drag, so it follows the pointer exactly.
    private func dragGesture(_ layout: CropCanvas) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == nil {
                    canvasFocused = true
                    drag = Drag(hit: layout.hit(value.startLocation, crop: geometry.crop), start: geometry)
                }
                guard let drag else { return }
                let delta = layout.fractions(of: value.translation)
                switch drag.hit {
                case .corner(let corner):
                    geometry = drag.start.dragged(corner, dx: delta.width, dy: delta.height)
                case .inside, .outside:  // dragging the frame or the photo moves the crop
                    NSCursor.closedHand.set()
                    geometry = drag.start.moved(dx: delta.width, dy: delta.height)
                }
            }
            .onEnded { _ in drag = nil }
    }

    /// Trackpad pinch, about the point where it started.
    private func pinchGesture(_ layout: CropCanvas) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? geometry
                pinchStart = start
                geometry = start.zoomed(by: value.magnification, about: layout.fraction(at: value.startLocation))
            }
            .onEnded { _ in pinchStart = nil }
    }

    private static func direction(of key: KeyEquivalent) -> CropGeometry.Direction {
        switch key {
        case .leftArrow: .left
        case .rightArrow: .right
        case .upArrow: .up
        default: .down
        }
    }

    // MARK: zoom slider

    private var zoomSlider: some View {
        Slider(value: zoomLevel, in: 0...max(log(geometry.maximumZoom), 0.01)) {
            Text(verbatim: strings[.cropZoom])
        } minimumValueLabel: {
            Image(systemName: "minus.magnifyingglass").accessibilityHidden(true)
        } maximumValueLabel: {
            Image(systemName: "plus.magnifyingglass").accessibilityHidden(true)
        }
        .disabled(!geometry.canZoom)
        .accessibilityValue(Text(verbatim: strings.cropZoomValue(geometry.zoom)))
    }

    /// The slider runs on a log scale, so each stretch of it zooms by the same factor; it
    /// zooms about the frame's centre.
    private var zoomLevel: Binding<Double> {
        Binding(get: { log(geometry.zoom) },
                set: { geometry = geometry.zoomed(to: exp($0), about: geometry.centre) })
    }
}

/// The dimmed outside of the crop, the frame's outline, its rule-of-thirds guides and the
/// corner handles. Dark edges under the white lines keep them visible on a light photo.
private struct CropOverlay: View {
    let imageFrame: CGRect
    let frame: CGRect

    var body: some View {
        Canvas { context, _ in
            var outside = Path(imageFrame)
            outside.addRect(frame)
            context.fill(outside, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

            var thirds = Path()
            for third in [1.0 / 3, 2.0 / 3] {
                let x = frame.minX + frame.width * third, y = frame.minY + frame.height * third
                thirds.move(to: CGPoint(x: x, y: frame.minY))
                thirds.addLine(to: CGPoint(x: x, y: frame.maxY))
                thirds.move(to: CGPoint(x: frame.minX, y: y))
                thirds.addLine(to: CGPoint(x: frame.maxX, y: y))
            }
            context.stroke(thirds, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
            context.stroke(Path(frame), with: .color(.black.opacity(0.4)), lineWidth: 2.5)
            context.stroke(Path(frame), with: .color(.white), lineWidth: 1)

            let arm = min(14, frame.width / 3, frame.height / 3)
            var handles = Path()
            for (x, y, dx, dy) in [(frame.minX, frame.minY, arm, arm), (frame.maxX, frame.minY, -arm, arm),
                                   (frame.minX, frame.maxY, arm, -arm), (frame.maxX, frame.maxY, -arm, -arm)] {
                handles.move(to: CGPoint(x: x + dx, y: y))
                handles.addLine(to: CGPoint(x: x, y: y))
                handles.addLine(to: CGPoint(x: x, y: y + dy))
            }
            context.stroke(handles, with: .color(.black.opacity(0.4)), style: StrokeStyle(lineWidth: 5, lineCap: .square))
            context.stroke(handles, with: .color(.white), style: StrokeStyle(lineWidth: 3, lineCap: .square))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Reports scroll-wheel and two-finger scrolls over its frame: `onScroll(delta, precise,
/// point)`, the point in the view's own coordinates (origin top left). SwiftUI on macOS 14
/// has no modifier for them. Clicks and drags pass through to the views around it.
private struct ScrollWheelReader: NSViewRepresentable {
    let onScroll: @MainActor (_ delta: Double, _ precise: Bool, _ point: CGPoint) -> Void

    func makeNSView(context: Context) -> ScrollWheelView {
        ScrollWheelView()
    }

    func updateNSView(_ view: ScrollWheelView, context: Context) {
        view.onScroll = onScroll
    }
}

private final class ScrollWheelView: NSView {
    var onScroll: (@MainActor (Double, Bool, CGPoint) -> Void)?
    /// Watches the window's scroll events while the view is in a window.
    private var monitor: EventMonitor?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        monitor = window == nil ? nil : EventMonitor(.scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) == true } ? nil : event
        }
    }

    /// True when the scroll was over this view and is used up.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let onScroll, event.scrollingDeltaY != 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return false }
        // Natural scrolling (the default) flips the sign; undo it, so the wheel or the fingers
        // moving away from the user zoom in whatever the setting.
        let delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        onScroll(delta, event.hasPreciseScrollingDeltas, point)
        return true
    }
}

/// A local event monitor, removed again when this goes away.
private final class EventMonitor {
    private let token: Any?

    init(_ events: NSEvent.EventTypeMask, handler: @escaping (NSEvent) -> NSEvent?) {
        token = NSEvent.addLocalMonitorForEvents(matching: events, handler: handler)
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}
