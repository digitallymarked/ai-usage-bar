import Cocoa

// MARK: - Colours: Flexoki by Steph Ango (https://stephango.com/flexoki, MIT)

func flexoki(dark: UInt32, light: UInt32) -> NSColor {
    func c(_ h: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                blue: CGFloat(h & 0xFF) / 255, alpha: 1)
    }
    return NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? c(dark) : c(light)
    }
}

enum Palette {
    // Dropdown rows: Flexoki 300 on dark, 600 on light.
    static let green = flexoki(dark: 0xA0AF54, light: 0x66800B)
    static let yellow = flexoki(dark: 0xDFB431, light: 0xAD8301)
    static let orange = flexoki(dark: 0xEC8B49, light: 0xBC5215)
    static let red = flexoki(dark: 0xE8705F, light: 0xAF3029)
    // Menu-bar ring: the dark menu bar is translucent mid-grey, so go lighter (200).
    static let ringGreen = flexoki(dark: 0xBEC97E, light: 0x66800B)
    static let ringYellow = flexoki(dark: 0xECCB60, light: 0xAD8301)
    static let ringOrange = flexoki(dark: 0xF9AE77, light: 0xBC5215)
    static let ringRed = flexoki(dark: 0xF89A8A, light: 0xAF3029)

    /// green < 50 % ≤ yellow < 70 % ≤ orange < 90 % ≤ red
    static func severity(_ p: Double, ring: Bool = false) -> NSColor {
        if p >= 90 { return ring ? ringRed : red }
        if p >= 70 { return ring ? ringOrange : orange }
        if p >= 50 { return ring ? ringYellow : yellow }
        return ring ? ringGreen : green
    }
}

// MARK: - Menu-bar ring

func ringImage(percent: Double?, size: CGFloat = 15) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        let lw: CGFloat = 3.0
        let r = rect.insetBy(dx: lw / 2 + 0.5, dy: lw / 2 + 0.5)
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = lw
        NSColor.labelColor.withAlphaComponent(0.15).setStroke()
        track.stroke()
        if let p = percent {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: NSPoint(x: r.midX, y: r.midY), radius: r.width / 2, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(max(p, 0), 100) / 100), clockwise: true)
            arc.lineWidth = lw
            arc.lineCapStyle = .round
            Palette.severity(p, ring: true).setStroke()
            arc.stroke()
        }
        return true
    }
}

// MARK: - Time formatting

func resetsIn(_ d: Date?) -> String {
    guard let d = d else { return "" }
    var s = Int(d.timeIntervalSinceNow)
    if s <= 0 { return "resetting…" }
    let days = s / 86400; s %= 86400
    let h = s / 3600, m = (s % 3600) / 60
    if days > 0 { return "resets in \(days)d \(h)h" }
    if h > 0 { return "resets in \(h)h \(m)m" }
    return "resets in \(m)m"
}

func clockTime(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "EEE HH:mm"
    return f.string(from: d)
}

// MARK: - Dropdown row

/// Label, % used, coloured bar and reset time.
final class BarRowView: NSView {
    init(_ info: LimitInfo) {
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 50))
        let title = NSTextField(labelWithString: info.label)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        let pct = NSTextField(labelWithString: "\(Int(info.percent.rounded()))% used")
        pct.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        pct.textColor = Palette.severity(info.percent)
        pct.alignment = .right
        let resetText = [resetsIn(info.resetsAt), clockTime(info.resetsAt)].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        let sub = NSTextField(labelWithString: resetText)
        sub.font = .systemFont(ofSize: 10.5)
        sub.textColor = .secondaryLabelColor
        let bar = NSView(); bar.wantsLayer = true
        bar.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
        bar.layer?.cornerRadius = 3
        let fill = NSView(); fill.wantsLayer = true
        fill.layer?.backgroundColor = Palette.severity(info.percent).cgColor
        fill.layer?.cornerRadius = 3
        title.frame = NSRect(x: 16, y: 28, width: 170, height: 16)
        pct.frame = NSRect(x: 180, y: 28, width: 86, height: 16)
        bar.frame = NSRect(x: 16, y: 20, width: 250, height: 6)
        fill.frame = NSRect(x: 0, y: 0, width: 250 * CGFloat(min(max(info.percent, 0), 100) / 100), height: 6)
        sub.frame = NSRect(x: 16, y: 2, width: 250, height: 15)
        bar.addSubview(fill)
        [title, pct, bar, sub].forEach(addSubview)
    }
    required init?(coder: NSCoder) { fatalError() }
}
