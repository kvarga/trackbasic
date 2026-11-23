// TrackBASIC: a QBasic-style IDE and interpreter whose PC speaker is the MacBook trackpad.

import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    var window: NSWindow!
    let ide = IDE()

    func applicationDidFinishLaunching(_ note: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.contentView = ide.view
        window.contentMinSize = NSSize(width: 640, height: 480)
        window.backgroundColor = .black
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TrackBASIC")
        ide.window = window
        buildMenus()

        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        if let path = args.first, let text = try? String(contentsOfFile: path, encoding: .utf8) {
            ide.load(text: text, url: URL(fileURLWithPath: path))
        } else if let url = exampleURLs().first(where: { $0.lastPathComponent.uppercased() == "WELCOME.BAS" }),
                  let text = try? String(contentsOf: url, encoding: .utf8) {
            ide.load(text: text, url: nil)
        } else {
            ide.newProgram()
        }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(ide.view)
        NSApp.activate(ignoringOtherApps: true)

        if CommandLine.arguments.contains("--run") { ide.run() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard let text = (try? String(contentsOfFile: filename, encoding: .utf8)) ?? (try? String(contentsOfFile: filename, encoding: .isoLatin1)) else { return false }
        ide.load(text: text, url: URL(fileURLWithPath: filename))
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ide.stop()
        return confirmDiscard() ? .terminateNow : .terminateCancel
    }

    // MARK: Menus

    private func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.keyEquivalentModifierMask = mods
        i.target = self
        return i
    }

    private func buildMenus() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About TrackBASIC", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide TrackBASIC", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit TrackBASIC", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = appMenu; main.addItem(appItem)

        let file = NSMenu(title: "File")
        file.addItem(item("New", #selector(newDoc), "n"))
        file.addItem(item("Open…", #selector(openDoc), "o"))
        let examples = NSMenu(title: "Examples")
        for url in exampleURLs() {
            let i = item(url.deletingPathExtension().lastPathComponent.capitalized, #selector(openExample(_:)))
            i.representedObject = url
            examples.addItem(i)
        }
        let exItem = NSMenuItem(title: "Examples", action: nil, keyEquivalent: ""); exItem.submenu = examples
        file.addItem(exItem)
        file.addItem(.separator())
        file.addItem(item("Save", #selector(saveDoc), "s"))
        file.addItem(item("Save As…", #selector(saveDocAs), "s", [.command, .shift]))
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let fileItem = NSMenuItem(); fileItem.submenu = file; main.addItem(fileItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Paste", #selector(pasteText), "v"))
        edit.addItem(item("Copy Program", #selector(copyProgram), "c", [.command, .shift]))
        let editItem = NSMenuItem(); editItem.submenu = edit; main.addItem(editItem)

        let run = NSMenu(title: "Run")
        run.addItem(item("Start", #selector(runProgram), "r"))
        run.addItem(item("Stop", #selector(stopProgram), "."))
        run.addItem(item("Output Screen", #selector(toggleOutput), "4"))
        let runItem = NSMenuItem(); runItem.submenu = run; main.addItem(runItem)

        let sound = NSMenu(title: "Sound")
        for (n, out) in SoundOutput.allCases.enumerated() {
            let i = item(out == .trackpad ? "Trackpad (haptic motor)" : out == .speakers ? "Speakers (square wave)" : "Off",
                         #selector(pickSound(_:)), "\(n + 1)", [.command, .option])
            i.representedObject = out.rawValue
            sound.addItem(i)
        }
        sound.addItem(.separator())
        sound.addItem(item("Test: Sweep 100 Hz to 4 kHz", #selector(testSweep)))
        let soundItem = NSMenuItem(); soundItem.submenu = sound; main.addItem(soundItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowItem = NSMenuItem(); windowItem.submenu = windowMenu; main.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pickSound(_:)):
            let out = SoundOutput(rawValue: menuItem.representedObject as? String ?? "")
            menuItem.state = out == Speaker.shared.output ? .on : .off
            return out != .trackpad || Speaker.shared.motor.available
        case #selector(stopProgram): return ide.isRunning
        case #selector(runProgram), #selector(newDoc), #selector(openDoc), #selector(openExample(_:)), #selector(testSweep):
            return !ide.isRunning
        default: return true
        }
    }

    // MARK: Files

    func exampleURLs() -> [URL] {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("Examples")) }
        dirs.append(URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("Examples"))
        dirs.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Examples"))
        for d in dirs {
            if let files = try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension.lowercased() == "bas" }), !files.isEmpty {
                return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        return []
    }

    private func confirmDiscard() -> Bool {
        guard ide.dirty else { return true }
        let a = NSAlert()
        a.messageText = "Save changes to \(ide.displayName)?"
        a.informativeText = "Your changes will be lost if you don't save them."
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Don't Save")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save(as: false)
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    @objc func newDoc() { if confirmDiscard() { ide.newProgram() } }

    @objc func openDoc() {
        guard confirmDiscard() else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "bas") ?? .plainText, .plainText]
        p.allowsOtherFileTypes = true
        guard p.runModal() == .OK, let url = p.url else { return }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
        ide.load(text: text, url: url)
    }

    @objc func openExample(_ sender: NSMenuItem) {
        guard confirmDiscard(), let url = sender.representedObject as? URL, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        ide.load(text: text, url: nil)
    }

    @discardableResult
    private func save(as: Bool) -> Bool {
        var url = ide.fileURL
        if url == nil || `as` {
            let p = NSSavePanel()
            p.allowedContentTypes = [UTType(filenameExtension: "bas") ?? .plainText]
            p.nameFieldStringValue = ide.fileURL?.lastPathComponent ?? "UNTITLED.BAS"
            guard p.runModal() == .OK, let u = p.url else { return false }
            url = u
        }
        do {
            try ide.text.write(to: url!, atomically: true, encoding: .utf8)
            ide.saved(to: url!)
            return true
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
    }

    @objc func saveDoc() { save(as: false) }
    @objc func saveDocAs() { save(as: true) }

    @objc func pasteText() {
        if let s = NSPasteboard.general.string(forType: .string) { ide.paste(s) }
    }

    @objc func copyProgram() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ide.text, forType: .string)
    }

    @objc func runProgram() { ide.run() }
    @objc func stopProgram() { ide.stop() }
    @objc func toggleOutput() { ide.toggleOutput() }

    @objc func pickSound(_ sender: NSMenuItem) {
        if let out = SoundOutput(rawValue: sender.representedObject as? String ?? "") { Speaker.shared.output = out; ide.refresh() }
    }

    @objc func testSweep() {
        DispatchQueue.global(qos: .userInitiated).async {
            var t = 0.0
            while t < 3 {
                let f = 100 * pow(40, t / 3)
                Speaker.shared.tone(hz: f, seconds: 0.03, stop: { false })
                t += 0.03
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { ide.stop(); return confirmDiscard() }
}

/// Headless test mode: `TrackBASIC --dump FILE.BAS [--keys "typed input"] [--silent]` runs the program and
/// prints the text screen it leaves behind.
if let i = CommandLine.arguments.firstIndex(of: "--dump"), i + 1 < CommandLine.arguments.count {
    let args = CommandLine.arguments
    let src = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
    if args.contains("--silent") { Speaker.shared.output = .off }
    let screen = Screen(), keys = KeyQueue()
    keys.capacity = Int.max
    if let k = args.firstIndex(of: "--keys"), k + 1 < args.count {
        for ch in args[k + 1] { keys.push(ch == "|" ? "\r" : String(ch)) }
    }
    var status: Int32 = 0
    do {
        let prog = try Parser.compile(src.components(separatedBy: "\n"))
        let interp = Interpreter(program: prog, screen: screen, keys: keys)
        if let t = args.firstIndex(of: "--timeout"), t + 1 < args.count, let secs = Double(args[t + 1]) {
            DispatchQueue.global().asyncAfter(deadline: .now() + secs) { interp.stopRequested = true }
        }
        try interp.run()
    } catch let e as ParseError {
        print("PARSE ERROR line \(e.line + 1): \(e.message)"); status = 1
    } catch let e as RunError {
        print("RUNTIME ERROR line \(e.line + 1): \(e.message)"); status = 1
    }
    var rows: [String] = []
    for r in 0..<screen.rows {
        var line = ""
        for c in 0..<screen.cols {
            let code = screen.codes[r * screen.cols + c]
            line.append(code < 256 ? cp437[Int(code)] : "?")
        }
        while line.hasSuffix(" ") { line.removeLast() }
        rows.append(line)
    }
    while rows.last == "" { rows.removeLast() }
    print(rows.joined(separator: "\n"))
    if screen.mode != 0 { print("[graphics mode \(screen.mode): \(screen.pixels.filter { $0 != 0 }.count) lit pixels]") }
    exit(status)
}

if CommandLine.arguments.contains("--bench") {
    // How long one MTActuationActuate call takes, for actuations of different lengths.
    let m = Speaker.shared.motor
    for ms in [1.0, 2, 5, 10, 20, 40] {
        var times: [Double] = []
        for _ in 0..<12 {
            let t0 = mach_absolute_time()
            m.play([(1000, 1)], ms: ms, level: 0.6)
            times.append(Double(mach_absolute_time() - t0) / ticksPerSecond * 1000)
            usleep(useconds_t(ms * 1000 + 30_000))
        }
        times.sort()
        print(String(format: "actuation %4.0f ms: call takes median %.2f ms, max %.2f ms", ms, times[6], times[11]))
    }
    for ms in [2.0, 5, 10, 19, 30] {
        let t0 = mach_absolute_time()
        for _ in 0..<20 { m.play([(1000, 1)], ms: ms, level: 0.6) }
        let per = Double(mach_absolute_time() - t0) / ticksPerSecond * 1000 / 20
        print(String(format: "back-to-back %4.0f ms actuations: %.1f ms per call", ms, per))
        usleep(300_000)
    }
    for ms in [10.0, 19] {
        var line = String(format: "%2.0f ms actuations, ms per call by level:", ms)
        for lvl in [0.5, 0.6, 0.7, 0.75, 0.8, 0.85, 0.9, 0.95, 1.0] as [Float] {
            let t0 = mach_absolute_time()
            for _ in 0..<20 { m.play([(784, 1)], ms: ms, level: lvl) }
            line += String(format: "  %.2f→%.1f", lvl, Double(mach_absolute_time() - t0) / ticksPerSecond * 1000 / 20)
            usleep(400_000)
        }
        print(line)
    }
    for secs in [0.22, 0.5] {
        let t0 = mach_absolute_time()
        Speaker.shared.tone(hz: 784, seconds: secs, stop: { false })
        print(String(format: "tone(%.2fs) took %.0f ms", secs, Double(mach_absolute_time() - t0) / ticksPerSecond * 1000))
        usleep(300_000)
    }
    let mic = MicRecorder(); try? mic.start(); usleep(300_000)
    let t1 = mach_absolute_time()
    Speaker.shared.tone(hz: 784, seconds: 0.5, stop: { false })
    print(String(format: "with mic running: tone(0.50s) took %.0f ms", Double(mach_absolute_time() - t1) / ticksPerSecond * 1000))
    mic.stop()
    exit(0)
}
if CommandLine.arguments.contains("--listen") { exit(runListen(CommandLine.arguments)) }

/// Render test: `TrackBASIC --png OUT.png [FILE.BAS]` draws the editor offscreen and saves it.
if let i = CommandLine.arguments.firstIndex(of: "--png"), i + 1 < CommandLine.arguments.count {
    let args = CommandLine.arguments
    let ide = IDE()
    if i + 2 < args.count, let text = try? String(contentsOfFile: args[i + 2], encoding: .utf8) {
        ide.load(text: text, url: URL(fileURLWithPath: args[i + 2]))
    }
    let v = ide.view
    v.frame = NSRect(x: 0, y: 0, width: 960, height: 720)
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[i + 1]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
