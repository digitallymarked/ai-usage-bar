import Cocoa

// MARK: - Flexoki surfaces

enum Surface {
    static let paper = flexoki(dark: 0x100F0F, light: 0xFFFCF0)
    static let card = flexoki(dark: 0x1C1B1A, light: 0xF2F0E5)
    static let border = flexoki(dark: 0x343331, light: 0xDAD8CE)
    static let accent = flexoki(dark: 0x4385BE, light: 0x205EA6)
}

/// Layer-backed view whose colours follow light/dark appearance.
class SurfaceView: NSView {
    var fill: NSColor
    var stroke: NSColor?
    init(fill: NSColor, stroke: NSColor? = nil, radius: CGFloat = 0) {
        self.fill = fill; self.stroke = stroke
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.borderWidth = stroke == nil ? 0 : 1
    }
    required init?(coder: NSCoder) { fatalError() }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill.cgColor
            layer?.borderColor = stroke?.cgColor
        }
    }
}

/// A clickable, keyboard-focusable provider row.
final class ProviderCard: SurfaceView {
    var onSelect: (() -> Void)?

    init(name: String, plan: String, signedIn: Bool) {
        super.init(fill: Surface.card, stroke: Surface.border, radius: 10)
        let title = label(name, size: 14, weight: .semibold)
        let sub = label("Needs \(plan)", size: 12, color: .secondaryLabelColor)
        let badge = label(signedIn ? "● Signed in" : "○ Not set up", size: 12, weight: .medium,
                          color: signedIn ? Palette.green : .secondaryLabelColor)
        let chevron = label("›", size: 18, color: .tertiaryLabelColor)
        let left = NSStackView(views: [title, sub]); left.orientation = .vertical; left.alignment = .leading; left.spacing = 2
        let row = NSStackView(views: [left, NSView(), badge, chevron]); row.spacing = 10; row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(name), needs \(plan), \(signedIn ? "signed in" : "not set up")")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { onSelect?() } else { super.keyDown(with: event) }
    }
    override func accessibilityPerformPress() -> Bool { onSelect?(); return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 10, yRadius: 10).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

func label(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
           color: NSColor = .labelColor, wrap: CGFloat? = nil) -> NSTextField {
    let t = wrap == nil ? NSTextField(labelWithString: s) : NSTextField(wrappingLabelWithString: s)
    t.font = .systemFont(ofSize: size, weight: weight)
    t.textColor = color
    if let w = wrap { t.preferredMaxLayoutWidth = w; t.isSelectable = true }
    return t
}

// MARK: - Controller

final class WizardController: NSObject, NSWindowDelegate {
    static let width: CGFloat = 480
    static let inner: CGFloat = 416

    let window: NSWindow
    private let root = SurfaceView(fill: Surface.paper)
    private let stepper = NSStackView()
    private let body = NSStackView()
    private let footer = NSStackView()
    private var primary: (() -> Void)?
    private var shotIndex = 0
    private var currentName = ""
    private var spinner: NSProgressIndicator?

    /// Called once the first fetch succeeded and the provider is saved.
    var onFinish: ((UsageProvider, UsageSnapshot) -> Void)?
    var onClose: (() -> Void)?

    private let env = ProcessInfo.processInfo.environment

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 430),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Set up AI Usage Bar"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = root
        switch env["AI_USAGE_BAR_APPEARANCE"] {
        case "dark": window.appearance = NSAppearance(named: .darkAqua)
        case "light": window.appearance = NSAppearance(named: .aqua)
        default: break
        }

        for s in [stepper, body, footer] { s.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(s) }
        stepper.spacing = 18
        body.orientation = .vertical; body.alignment = .leading; body.spacing = 12
        footer.spacing = 10
        NSLayoutConstraint.activate([
            stepper.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            stepper.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            body.topAnchor.constraint(equalTo: stepper.bottomAnchor, constant: 22),
            body.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            body.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 32),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
    }

    // MARK: presenting

    func show(provider: UsageProvider? = nil) {
        if let p = provider { connect(p) } else { choose() }
        // Accessory apps don't get focus automatically: become a regular app while the wizard is
        // open (Dock icon appears), then go back to menu-bar-only when it closes.
        NSApp.setActivationPolicy(.regular)
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.log("active=\(NSApp.isActive) key=\(self?.window.isKeyWindow ?? false)")
        }
        runDebugActions()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }

    private func render(step: Int, name: String, content: [NSView], buttons: [NSButton], primaryAction: (() -> Void)? = nil) {
        currentName = name
        primary = primaryAction
        stepper.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, t) in ["1  Choose", "2  Connect", "3  Done"].enumerated() {
            let l = label(t, size: 12, weight: .medium, color: i + 1 == step ? .labelColor : .tertiaryLabelColor)
            l.setAccessibilityLabel("Step \(i + 1) of 3: \(t.dropFirst(3))" + (i + 1 == step ? ", current" : ""))
            stepper.addArrangedSubview(l)
        }
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        spinner = nil
        for v in content {
            body.addArrangedSubview(v)
            if v is ProviderCard || v is SurfaceView { v.widthAnchor.constraint(equalToConstant: Self.inner).isActive = true }
        }
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for b in buttons { footer.addArrangedSubview(b) }
        footer.layoutSubtreeIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.snapshot(name) }
        if let first = body.arrangedSubviews.first(where: { $0 is ProviderCard }) { window.makeFirstResponder(first) }
        log("step=\(name)")
    }

    private func button(_ title: String, primary isPrimary: Bool = false, _ action: @escaping () -> Void) -> NSButton {
        let b = ClosureButton(title: title, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        if isPrimary { b.keyEquivalent = "\r" }
        return b
    }

    private func heading(_ title: String, _ sub: String) -> [NSView] {
        [label(title, size: 22, weight: .semibold),
         label(sub, size: 13, color: .secondaryLabelColor, wrap: Self.inner)]
    }

    // MARK: step 1

    func choose() {
        var views = heading("Which AI provider do you use?", "The menu-bar ring will show your usage for the one you pick. You can change it later.")
        for p in Providers.all {
            let signedIn: Bool = { if case .signedIn = p.setupStatus() { return true } else { return false } }()
            let card = ProviderCard(name: p.name, plan: p.planRequired, signedIn: signedIn)
            card.onSelect = { [weak self] in self?.connect(p) }
            views.append(card)
        }
        render(step: 1, name: "choose", content: views, buttons: [button("Not now") { [weak self] in self?.window.close() }])
    }

    // MARK: step 2

    func connect(_ p: UsageProvider) {
        switch p.setupStatus() {
        case .needsSetup(let guide):
            showGuide(p, guide, note: nil)
        case .signedIn:
            if let text = p.connectNotice {
                var views = heading("Connect \(p.name)", "Found your \(p.name) login on this Mac.")
                views.append(notice(text))
                render(step: 2, name: "connect-\(p.id)-ready", content: views,
                       buttons: [button("Back") { [weak self] in self?.choose() },
                                 button("Connect", primary: true) { [weak self] in self?.check(p) }],
                       primaryAction: { [weak self] in self?.check(p) })
            } else {
                check(p)
            }
        }
    }

    private func notice(_ text: String) -> NSView {
        let box = SurfaceView(fill: Surface.card, stroke: Surface.border, radius: 8)
        let l = label(text, size: 12, color: .labelColor, wrap: Self.inner - 28)
        l.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(l)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            l.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            l.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            l.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
        ])
        return box
    }

    private func showGuide(_ p: UsageProvider, _ guide: SetupGuide, note: String?) {
        var views: [NSView] = [label("Connect \(p.name)", size: 22, weight: .semibold),
                               label(guide.headline, size: 13, weight: .medium, color: Palette.orange, wrap: Self.inner)]
        if let n = note { views.append(label(n, size: 12, color: .secondaryLabelColor, wrap: Self.inner)) }
        for (i, s) in guide.steps.enumerated() {
            views.append(label("\(i + 1).  \(s)", size: 13, wrap: Self.inner))
            // Show the copyable command under the step that introduces it.
            if i == 0, let copy = guide.actions.first(where: { if case .copy = $0.kind { return true } else { return false } }),
               case .copy(let cmd) = copy.kind {
                views.append(commandBox(cmd))
            }
        }
        var buttons: [NSButton] = [button("Back") { [weak self] in self?.choose() }]
        for a in guide.actions {
            switch a.kind {
            case .copy: continue
            case .openURL(let u): buttons.append(button(a.title) { NSWorkspace.shared.open(u) })
            case .runInTerminal(let c): buttons.append(button(a.title) { Self.runInTerminal(c) })
            }
        }
        buttons.append(button("Check again", primary: true) { [weak self] in self?.check(p) })
        render(step: 2, name: "connect-\(p.id)-guide", content: views, buttons: buttons,
               primaryAction: { [weak self] in self?.check(p) })
    }

    private func commandBox(_ cmd: String) -> NSView {
        let box = SurfaceView(fill: Surface.card, stroke: Surface.border, radius: 8)
        let t = NSTextField(labelWithString: cmd)
        t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        t.isSelectable = true
        let copy = button("Copy") { [weak self] in
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(cmd, forType: .string)
            self?.log("copied command")
        }
        copy.controlSize = .small
        let row = NSStackView(views: [t, NSView(), copy]); row.alignment = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
        ])
        return box
    }

    static func runInTerminal(_ command: String) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-usage-bar-\(UUID().uuidString.prefix(8)).command")
        let script = "#!/bin/zsh -l\nclear\n\(command)\n"
        guard (try? script.write(to: url, atomically: true, encoding: .utf8)) != nil else { return }
        chmod(url.path, 0o755)
        NSWorkspace.shared.open(url)
    }

    /// Re-detect, then run a real fetch.
    private func check(_ p: UsageProvider) {
        guard case .signedIn = p.setupStatus() else {
            if case .needsSetup(let g) = p.setupStatus() {
                showGuide(p, g, note: "Still not detected. Finish signing in, then check again.")
            }
            return
        }
        let sp = NSProgressIndicator(); sp.style = .spinning; sp.controlSize = .small; sp.startAnimation(nil)
        let row = NSStackView(views: [sp, label("Fetching your \(p.name) usage…", color: .secondaryLabelColor)]); row.spacing = 8
        render(step: 2, name: "connect-\(p.id)-fetching",
               content: heading("Connect \(p.name)", "Checking that the bar can read your usage.") + [row], buttons: [])
        Task {
            let result: Result<UsageSnapshot, Error>
            do { result = .success(try await p.fetch()) } catch { result = .failure(error) }
            await MainActor.run {
                switch result {
                case .success(let s): self.finish(p, s)
                case .failure(let e): self.failed(p, e)
                }
            }
        }
    }

    private func failed(_ p: UsageProvider, _ error: Error) {
        let hint: String
        switch error as? FetchError {
        case .notSignedIn?, .http(401)?, .http(403)?, .refreshFailed?:
            hint = "Your \(p.name) session needs signing in again. Sign in, then try again."
        case .network?:
            hint = "The bar couldn't reach \(p.name). Check your internet connection, then try again."
        case .http(429)?:
            hint = "\(p.name) is rate-limiting the bar right now. Wait a minute, then try again."
        default:
            hint = "\(p.name) answered in a way the bar doesn't understand. Try again; if it keeps happening, the provider may have changed its API."
        }
        var views = heading("Couldn't connect \(p.name)", hint)
        views.append(notice("\(error)"))
        var buttons: [NSButton] = [button("Back") { [weak self] in self?.choose() }]
        if let a = p.reconnectAction, case .runInTerminal(let c) = a.kind { buttons.append(button(a.title) { Self.runInTerminal(c) }) }
        buttons.append(button("Try again", primary: true) { [weak self] in self?.check(p) })
        render(step: 2, name: "connect-\(p.id)-failed", content: views, buttons: buttons, primaryAction: { [weak self] in self?.check(p) })
    }

    // MARK: step 3

    private func finish(_ p: UsageProvider, _ s: UsageSnapshot) {
        Providers.selected = p
        Settings.setupComplete = true
        onFinish?(p, s)

        var views = heading("\(p.name) is connected", "")
        views.removeLast()
        if let top = s.primary ?? s.others.first {
            let big = label("\(top.label)  \(Int(top.percent.rounded()))%", size: 28, weight: .semibold, color: Palette.severity(top.percent))
            let ring = NSImageView(image: ringImage(percent: top.percent, size: 28))
            let row = NSStackView(views: [ring, big]); row.spacing = 12; row.alignment = .centerY
            views.append(row)
            let reset = resetsIn(top.resetsAt)
            views.append(label(reset.isEmpty ? "That's your current usage." : "Used so far, \(reset).", size: 13, color: .secondaryLabelColor, wrap: Self.inner))
        } else {
            views.append(label("Connected, but \(p.name) didn't report any limits for this account yet.", size: 13, color: .secondaryLabelColor, wrap: Self.inner))
        }
        views.append(notice("Look for the ring in the top-right of your menu bar, next to the clock. It fills as you use your plan. Click it for every limit and its reset time."))
        render(step: 3, name: "done", content: views,
               buttons: [button("Done", primary: true) { [weak self] in self?.window.close() }],
               primaryAction: { [weak self] in self?.window.close() })
    }

    // MARK: test hooks (only active when env vars are set)

    private func log(_ s: String) {
        if env["AI_USAGE_BAR_WIZARD_LOG"] != nil { print("wizard: \(s)"); fflush(stdout) }
    }

    private func snapshot(_ name: String) {
        guard let dir = env["AI_USAGE_BAR_WIZARD_SNAPSHOTS"], name == currentName else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        shotIndex += 1
        let path = "\(dir)/\(String(format: "%02d", shotIndex))-\(name).png"
        // Prefer a true window capture (real button rendering); fall back to a view snapshot.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        try? p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 || !FileManager.default.fileExists(atPath: path) {
            let v = root
            guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        log("snapshot \(path)")
    }

    /// AI_USAGE_BAR_WIZARD_ACTIONS="pick:claude,primary,primary" drives the wizard without a human.
    private func runDebugActions() {
        guard let list = env["AI_USAGE_BAR_WIZARD_ACTIONS"] else { return }
        var delay = 1.5
        for a in list.split(separator: ",").map(String.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                if a.hasPrefix("pick:"), let p = Providers.all.first(where: { $0.id == a.dropFirst(5) }) { self.connect(p) }
                else if a == "primary" { self.primary?() }
            }
            delay += 2.5
        }
    }
}

final class ClosureButton: NSButton {
    private let handler: () -> Void
    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}

