import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var provider: UsageProvider = Providers.selected
    var snapshot: UsageSnapshot?
    var lastError: String?
    var generation = 0
    let pollInterval: TimeInterval = 120

    func applicationDidFinishLaunching(_ n: Notification) {
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu(); menu.delegate = self
        item.menu = menu
        render()
        refresh()
        Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in self?.refresh() }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.render() }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self?.refresh() }
        }
    }

    func refresh() {
        let p = provider, gen = generation
        Task {
            let result: Result<UsageSnapshot, Error>
            do { result = .success(try await p.fetch()) } catch { result = .failure(error) }
            await MainActor.run {
                guard gen == self.generation else { return }
                switch result {
                case .success(let s): self.snapshot = s; self.lastError = nil
                case .failure(let e): self.lastError = "\(e)"
                }
                self.render()
            }
        }
    }

    func render() {
        guard let b = item.button else { return }
        let pct = snapshot?.primary?.percent
        b.image = ringImage(percent: pct)
        b.toolTip = "\(provider.name) usage"
        let text = pct.map { " \(Int($0.rounded()))%" } ?? (lastError == nil ? " …" : " !")
        b.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        if let m = item.menu { buildMenu(m) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if let s = snapshot, Date().timeIntervalSince(s.fetchedAt) > 30 { refresh() }
        buildMenu(menu)
    }

    func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "\(provider.name) usage", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        if let s = snapshot {
            for info in [s.primary].compactMap({ $0 }) + s.others {
                let mi = NSMenuItem(); mi.view = BarRowView(info); menu.addItem(mi)
            }
        }
        if let e = lastError {
            let mi = NSMenuItem(title: "⚠︎ \(e)", action: nil, keyEquivalent: "")
            mi.isEnabled = false
            menu.addItem(mi)
        }
        menu.addItem(.separator())
        let updated = NSMenuItem(title: snapshot.map { "Updated \(clockTime($0.fetchedAt))" } ?? "Not updated yet",
                                 action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)
        menu.addItem(withTitle: "Refresh now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Open \(provider.name) usage page", action: #selector(openUsage), keyEquivalent: "u").target = self

        let providerMenu = NSMenu()
        for (i, p) in Providers.all.enumerated() {
            let mi = NSMenuItem(title: p.name, action: #selector(chooseProvider(_:)), keyEquivalent: "")
            mi.target = self
            mi.tag = i
            mi.state = p.id == provider.id ? .on : .off
            providerMenu.addItem(mi)
        }
        let providerItem = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        providerItem.submenu = providerMenu
        menu.addItem(providerItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(quit), keyEquivalent: "q").target = self
    }

    @objc func chooseProvider(_ sender: NSMenuItem) {
        let p = Providers.all[sender.tag]
        guard p.id != provider.id else { return }
        Providers.selected = p
        provider = p
        generation += 1
        snapshot = nil
        lastError = nil
        render()
        refresh()
    }

    @objc func refreshNow() { refresh() }
    @objc func openUsage() { NSWorkspace.shared.open(provider.usagePageURL) }
    @objc func quit() { NSApp.terminate(nil) }
}

func runSnapshot(providerID: String, out: String) {
    guard let p = Providers.all.first(where: { $0.id == providerID }) else {
        print("unknown provider \(providerID); options: \(Providers.all.map(\.id).joined(separator: ", "))")
        exit(2)
    }
    Task {
        do {
            let s = try await p.fetch()
            await MainActor.run {
                let rows = ([s.primary].compactMap { $0 } + s.others).map(BarRowView.init)
                let h = max(CGFloat(rows.count) * 50, 1)
                let v = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: h))
                v.appearance = NSAppearance(named: .darkAqua)
                v.wantsLayer = true
                v.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
                for (i, r) in rows.enumerated() { r.frame.origin.y = h - CGFloat(i + 1) * 50; v.addSubview(r) }
                let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
                for r in [s.primary].compactMap({ $0 }) + s.others {
                    print("\(r.label): \(Int(r.percent.rounded()))% \(resetsIn(r.resetsAt))")
                }
                exit(0)
            }
        } catch {
            print("error: \(error)")
            exit(1)
        }
    }
}

let app = NSApplication.shared
let args = CommandLine.arguments
if args.count == 4, args[1] == "--snapshot" {
    runSnapshot(providerID: args[2], out: args[3])
    app.run()
}
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
