import Foundation
import PaperhueAgenda
import UlaniKit

extension CalendarPages {
    /// The to-do page (LAYOUTS.md 6; Python: `render_todo`): the open tasks as a list, overdue in
    /// red and due today in blue; a long list grouped into 逾期 / 今天 / 之後 / 未排定 sections.
    public static func todo(_ data: AgendaData, today: LocalDate, zone: TimeZone,
                            background: Frame? = nil) -> PageCanvas {
        var page = canvas(background)
        TodoPage.draw(&page, data, today, zone)
        return page
    }
}

/// The to-do page's lists and their geometry (layouts.py "To-do").
enum TodoPage {
    private typealias G = PageGeometry

    /// 待辦事項, blue bold, on the header baseline.
    static let titleSize = 32
    /// The open count, blue bold, right-aligned on the header baseline.
    static let countSize = 44
    /// "1 項已逾期·1 項今天到期" (red / blue bold 18) and the sync stamp.
    static let summaryBase = 86
    static let top = 96
    static let height = G.bottom - top
    static let columnW = 350, gutter = 44
    /// A single column.
    static let fullW = PageCanvas.width - 2 * G.margin

    /// A two-line row: ring, title, then "due·list·notes".
    struct RowStyle {
        let ringR, titleSize, detailSize, pitch, titleDY, detailDY: Int
    }

    /// Up to 5 rows per column.
    static let large = RowStyle(ringR: 13, titleSize: 26, detailSize: 20, pitch: 72, titleDY: 30, detailDY: 58)
    /// Up to 7 rows per column.
    static let normal = RowStyle(ringR: 11, titleSize: 22, detailSize: 18, pitch: 52, titleDY: 24, detailDY: 46)

    /// Sections (long lists): uniform slots, 8 per column, 2 columns.
    static let slotH = 44
    static let slotsPerColumn = height / slotH
    static let sectionSize = 20

    enum Kind { case overdue, today, later, undated }

    static func kind(_ t: AgendaTask, _ today: LocalDate) -> Kind {
        guard let due = t.due else { return .undated }
        return due < today ? .overdue : due == today ? .today : .later
    }

    static func ringColour(_ kind: Kind) -> PanelColour {
        switch kind {
        case .overdue: .red
        case .today: .blue
        case .later, .undated: .black
        }
    }

    /// "昨天" or "逾期 N 天".
    static func overdueLabel(_ due: LocalDate, _ today: LocalDate) -> String {
        let days = due.distance(to: today)
        return days == 1 ? "昨天" : "逾期 \(days) 天"
    }

    static func draw(_ p: inout PageCanvas, _ data: AgendaData, _ today: LocalDate, _ zone: TimeZone) {
        let tasks = data.sortedTasks()
        let right = PageCanvas.width - G.margin
        p.text("待辦事項", x: G.margin, y: G.headerBase, size: titleSize, bold: true, fill: .blue)
        p.text(String(tasks.count), x: right, y: G.headerBase, size: countSize, bold: true, fill: .blue, anchor: .right)

        let overdue = tasks.filter { kind($0, today) == .overdue }.count
        let dueToday = tasks.filter { kind($0, today) == .today }.count
        var parts: [Part] = []
        if overdue > 0 { parts.append(Part(text: "\(overdue) 項已逾期", colour: .red, bold: true)) }
        if dueToday > 0 { parts.append(Part(text: "\(dueToday) 項今天到期", colour: .blue, bold: true)) }
        partsLine(&p, x: G.margin, base: summaryBase, w: 500, parts, size: PageText.noteSize)
        p.text(data.syncText(today: today, in: zone), x: right, y: summaryBase, size: PageText.syncSize, anchor: .right)

        if tasks.isEmpty {
            done(&p)
        } else if !list(&p, tasks, today) {
            sections(&p, tasks, today)
        }
    }

    /// One segment of a second line.
    struct Part {
        let text: String
        var colour: PanelColour = .black
        var bold = false
    }

    /// A row's second line: the due label (red bold when overdue, blue bold when due today),
    /// the date when it is overdue by more than a day, then the list and the notes.
    static func parts(_ t: AgendaTask, _ today: LocalDate) -> [Part] {
        var parts: [Part] = []
        if let due = t.due {
            switch kind(t, today) {
            case .overdue:
                parts.append(Part(text: overdueLabel(due, today), colour: .red, bold: true))
                if due.distance(to: today) > 1 { parts.append(Part(text: DayText.md(due, reference: today))) }
            case .today:
                parts.append(Part(text: "今天", colour: .blue, bold: true))
            case .later, .undated:
                parts.append(Part(text: today.distance(to: due) == 1
                                  ? "明天" : "\(DayText.md(due, reference: today)) \(DayText.weekdayShort(due))"))
            }
        }
        for extra in [t.listName, t.notes] {
            let text = PageFonts.clean(extra)
            if !text.isEmpty { parts.append(Part(text: text)) }
        }
        return parts
    }

    /// Draws the segments left to right joined by "·"; the one that overflows gets "…" and
    /// ends the line.
    static func partsLine(_ p: inout PageCanvas, x: Int, base: Int, w: Int, _ parts: [Part], size: Int) {
        let end = x + w
        var x = x
        for (i, part) in parts.enumerated() {
            if i > 0 {
                if Double(x) + PageFont(size: size).length(PageText.separator) >= Double(end) { return }
                x += p.text(PageText.separator, x: x, y: base, size: size)
            }
            let drawn = p.text(part.text, x: x, y: base, size: size, bold: part.bold, fill: part.colour, maxWidth: end - x)
            if Double(drawn) < PageFont(size: size, bold: part.bold).length(part.text) { return }
            x += drawn
        }
    }

    /// A flat list of two-line rows if every task fits in one or two columns (large rows, then
    /// normal ones); false if not.
    static func list(_ p: inout PageCanvas, _ tasks: [AgendaTask], _ today: LocalDate) -> Bool {
        let n = tasks.count
        let layouts: [(columns: Int, style: RowStyle)] = [(1, large), (1, normal), (2, large), (2, normal)]
        guard let layout = layouts.first(where: { n <= height / $0.style.pitch * $0.columns }) else { return false }
        let (columns, style) = layout
        let rows = (n + columns - 1) / columns  // balanced columns, filled top to bottom
        let w = columns == 1 ? fullW : columnW
        for (i, t) in tasks.enumerated() {
            let (c, r) = i.quotientAndRemainder(dividingBy: rows)
            let x = G.margin + c * (columnW + gutter), y = top + r * style.pitch
            let ringCY = y + style.titleDY - Int((Double(style.titleSize) * 0.38).rounded(.toNearestOrEven))
            p.ring(cx: Double(x + style.ringR), cy: Double(ringCY), r: style.ringR, colour: ringColour(kind(t, today)))
            let tx = x + 2 * style.ringR + 12
            p.text(PageText.title(t.title), x: tx, y: y + style.titleDY, size: style.titleSize, maxWidth: x + w - tx)
            partsLine(&p, x: tx, base: y + style.detailDY, w: x + w - tx, parts(t, today), size: style.detailSize)
            if r != rows - 1 && i != n - 1 {  // a hairline between rows of a column
                p.hairlineH(x0: tx, x1: x + w, y: y + style.pitch - 1)
            }
        }
        return true
    }

    /// One 44 px slot of the sections layout.
    enum Slot {
        case blank
        /// A section's name and count (the index into the sections).
        case header(Int)
        case task(AgendaTask)
        /// "還有 N 項".
        case more(Int)
    }

    /// Long lists: 逾期 / 今天 / 之後 / 未排定 sections flowing through two columns of slots.
    /// A header never ends a column, and a section that goes on in the next column repeats its
    /// header there. Every section shows at least one task; then 逾期 and 今天 grow
    /// round-robin while they fit, then 之後 and 未排定.
    static func sections(_ p: inout PageCanvas, _ tasks: [AgendaTask], _ today: LocalDate) {
        let groups: [(name: String, colour: PanelColour, kind: Kind)] = [
            ("逾期", .red, .overdue), ("今天", .blue, .today), ("之後", .black, .later), ("未排定", .black, .undated),
        ]
        var sections = groups.map { g in (g.name, g.colour, tasks: tasks.filter { kind($0, today) == g.kind }) }
            .filter { !$0.tasks.isEmpty }

        /// The slots for `shown` tasks per section, or nil if they overflow.
        func flow(_ shown: [Int]) -> [Slot]? {
            var slots: [Slot] = []
            for (s, k) in shown.enumerated() {
                if slots.count % slotsPerColumn == slotsPerColumn - 1 { slots.append(.blank) }
                slots.append(.header(s))
                let count = sections[s].tasks.count
                let body = sections[s].tasks.prefix(k).map(Slot.task) + (k < count ? [.more(count - k)] : [])
                for item in body {
                    if slots.count % slotsPerColumn == 0 { slots.append(.header(s)) }  // sticky header
                    slots.append(item)
                }
            }
            return slots.count <= 2 * slotsPerColumn ? slots : nil
        }

        var shown = Array(repeating: 1, count: sections.count)
        while flow(shown) == nil && sections.count > 1 {  // cannot happen with 4 sections, as in the reference
            sections.removeLast()
            shown.removeLast()
        }
        for phase in [["逾期", "今天"], ["之後", "未排定"]] {
            let indices = sections.indices.filter { phase.contains(sections[$0].0) }
            var grew = true
            while grew {
                grew = false
                for i in indices where shown[i] < sections[i].tasks.count {
                    shown[i] += 1
                    if flow(shown) == nil { shown[i] -= 1 } else { grew = true }
                }
            }
        }

        for (s, slot) in (flow(shown) ?? []).enumerated() {
            let (c, r) = s.quotientAndRemainder(dividingBy: slotsPerColumn)
            let x = G.margin + c * (columnW + gutter), y = top + r * slotH
            let tx = x + 34, base = y + 30
            switch slot {
            case .blank:
                break
            case let .header(i):
                let (name, colour, items) = sections[i]
                p.text(name, x: x, y: base, size: sectionSize, bold: true, fill: colour)
                p.text(String(items.count), x: x + columnW, y: base, size: sectionSize, bold: true, fill: colour, anchor: .right)
                p.hairlineH(x0: x, x1: x + columnW, y: y + 38)
            case let .more(n):
                p.text(DayText.more(n), x: tx, y: y + 28, size: PageText.noteSize)
            case let .task(t):
                let k = kind(t, today)
                p.ring(cx: Double(x + 11), cy: Double(base - 8), r: 11, colour: ringColour(k))
                // the section header already says 今天 / 未排定: those show the list instead
                var label = Part(text: PageFonts.clean(t.listName))
                if let due = t.due, k == .overdue {
                    label = Part(text: overdueLabel(due, today), colour: .red, bold: true)
                } else if let due = t.due, k == .later {
                    label = Part(text: today.distance(to: due) == 1 ? "明天" : DayText.md(due, reference: today))
                }
                let lw = label.text.isEmpty ? 0 : p.text(label.text, x: x + columnW, y: base, size: PageText.noteSize,
                                                         bold: label.bold, fill: label.colour, anchor: .right,
                                                         maxWidth: columnW / 3) + 12
                p.text(PageText.title(t.title), x: tx, y: base, size: 22, maxWidth: x + columnW - tx - lw)
            }
        }
    }

    /// Nothing to do: a blue check in a circle.
    static func done(_ p: inout PageCanvas) {
        let cx = PageCanvas.width / 2, cy = 224
        p.ring(cx: Double(cx), cy: Double(cy), r: 32, colour: .blue, width: 3)
        p.line([(cx - 14, cy + 1), (cx - 4, cy + 11), (cx + 15, cy - 10)], colour: .blue, width: 4)
        p.text("沒有待辦事項", x: cx, y: 304, size: 30, bold: true, anchor: .centre)
        p.text("全部完成了", x: cx, y: 338, size: 20, anchor: .centre)
    }
}
