import AppKit
import ApplicationServices
import RecorderCore
import ServiceManagement
import Darwin
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var status: NSStatusItem!
    private let menu = NSMenu()
    private let toggleItem = NSMenuItem(title: "Turn Recording ON", action: #selector(toggle), keyEquivalent: "")
    private let stateItem = NSMenuItem(title: "Off — no input collected", action: nil, keyEquivalent: "")
    private let capture = Capture()
    private var writer: JSONLWriter?
    private var armed = false
    private var suspended = false
    private var suspensionReasons: Set<String> = []
    private var finishing = false
    private var quitAfterFinish = false
    private var fault: String?
    private var lastSaveSummary: String?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var instanceLock: Int32 = -1
    private let defaults = UserDefaults.standard
    private var textEnabled: Bool { !defaults.bool(forKey: "omitText") }
    private var titlesEnabled: Bool { !defaults.bool(forKey: "omitTitles") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent accidental duplicate app instances recording the same input twice.
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("com.gavinzdarko.GhostRecorder.\(getuid()).lock")
        instanceLock = Darwin.open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            NSApp.terminate(nil); return
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.menu = menu
        menu.delegate = self
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Ghost Recorder", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        stateItem.isEnabled = false
        menu.addItem(stateItem)
        menu.addItem(.separator())
        toggleItem.target = self; menu.addItem(toggleItem)
        add("Record typed characters", #selector(toggleText))
        add("Record window titles", #selector(toggleTitles))
        add("Resume recording when app opens", #selector(toggleResume))
        add("Launch at login", #selector(toggleLogin))
        menu.addItem(.separator())
        add("Open Recordings Folder", #selector(openRecordings))
        add("Enable Input Monitoring…", #selector(inputPermission))
        add("Enable window context permission…", #selector(contextPermission))
        add("About / Data Details…", #selector(about))
        menu.addItem(.separator())
        add("Quit Ghost Recorder", #selector(quit))
        capture.record = { [weak self] in self?.writer?.enqueue($0) }
        capture.statusChanged = { [weak self] _ in self?.refresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        for (sleep, wake, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system_sleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "display_sleep"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "inactive_session")
        ] {
            observers.append(workspace.addObserver(forName: sleep, object: nil, queue: .main) { [weak self] _ in
                self?.suspensionReasons.insert(reason); self?.suspend()
            })
            observers.append(workspace.addObserver(forName: wake, object: nil, queue: .main) { [weak self] _ in
                self?.suspensionReasons.remove(reason); self?.resume()
            })
        }
        // These practical lock notifications are undocumented; the health timer also
        // checks the current session dictionary, and no protected-input bypass is used.
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            observers.append(DistributedNotificationCenter.default().addObserver(forName: Notification.Name(name),
                object: nil, queue: .main) { [weak self] _ in
                    if locked { self?.suspensionReasons.insert("screen_locked"); self?.suspend() }
                    else { self?.suspensionReasons.remove("screen_locked"); self?.resume() }
                })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                if self?.armed == true { self?.capture.boundary("display_layout_changed"); self?.capture.recordDisplays() }
            })
        timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.checkHealth() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        refresh()
        if defaults.bool(forKey: "resumeOnLaunch") && defaults.bool(forKey: "recordingIntent") { start() }
    }

    private func add(_ title: String, _ selector: Selector) {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self; menu.addItem(item)
    }
    func menuWillOpen(_ menu: NSMenu) { refresh() }
    private func refresh() {
        guard status != nil else { return }
        let snapshot = writer?.snapshot()
        let secure = IsSecureEventInputEnabled()
        let active = armed && !suspended && !secure && fault == nil
        status.button?.image = NSImage(systemSymbolName: active ? "record.circle.fill" : "record.circle", accessibilityDescription: "Ghost Recorder")
        status.button?.contentTintColor = active ? .systemRed : .secondaryLabelColor
        status.button?.title = active ? " REC" : (armed ? " PAUSED" : " OFF")
        status.button?.toolTip = "Ghost Recorder — \(active ? "recording locally" : "not collecting input")"
        stateItem.title = fault ?? (finishing ? "Saving…" : (armed ? (suspended ? "Paused — screen inactive / asleep" : (secure ? "Paused — protected input" : "Recording • \(snapshot?.writtenRecords ?? 0) events • \(snapshot?.droppedRecords ?? 0) dropped")) : (lastSaveSummary ?? "Off — no input collected")))
        toggleItem.title = armed ? "Turn Recording OFF" : "Turn Recording ON"
        toggleItem.isEnabled = !finishing
        for item in menu.items {
            if item.action == #selector(toggleText) { item.state = textEnabled ? .on : .off; item.isEnabled = !armed && !finishing }
            if item.action == #selector(toggleTitles) { item.state = titlesEnabled ? .on : .off; item.isEnabled = !armed && !finishing }
            if item.action == #selector(toggleResume) { item.state = defaults.bool(forKey: "resumeOnLaunch") ? .on : .off }
            if item.action == #selector(toggleLogin) { item.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        }
    }
    @objc private func toggle() { armed ? stop() : start() }
    private func start() {
        guard !armed && !finishing else { return }
        guard sessionIsActive() && suspensionReasons.isEmpty else {
            show("Recording is paused", "Unlock the screen and activate your session before starting recording."); return
        }
        if !defaults.bool(forKey: "acknowledged") {
            let alert = NSAlert()
            alert.messageText = "Record your keyboard and mouse locally?"
            alert.informativeText = "While ON, Ghost Recorder saves key press/release timing, \(textEnabled ? "typed characters, " : "")mouse movement/clicks/scroll, app names\(titlesEnabled ? " and available window titles" : ""). Recordings stay in your Library, outside the public code repository. Protected input is skipped; other sensitive text may still be recorded. Turn OFF before entering anything you do not want saved. This records input events, not a complete document or browser history."
            alert.addButton(withTitle: "Start Recording"); alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            defaults.set(true, forKey: "acknowledged")
        }
        do {
            fault = nil
            lastSaveSummary = nil
            writer = try JSONLWriter()
            capture.sessionID = UUID().uuidString
            capture.includeText = textEnabled; capture.includeTitles = titlesEnabled
            try capture.start()
            armed = true; suspended = false
            defaults.set(true, forKey: "recordingIntent")
        } catch {
            writer?.finish(); writer = nil
            fault = "Off — input access unavailable"
            show("Could not start recording", error.localizedDescription)
        }
        refresh()
    }
    private func stop() {
        guard armed else { return }
        capture.stop("recording_stopped")
        armed = false; suspended = false; finishing = true
        defaults.set(false, forKey: "recordingIntent")
        let closing = writer
        closing?.finish { [weak self] in
            guard let self else { return }
            let saved = closing?.snapshot()
            if let error = saved?.lastError { self.fault = "Save failed: \(error)" }
            else { self.lastSaveSummary = "OFF • saved \(saved?.writtenRecords ?? 0) events to disk" }
            self.writer = nil; self.finishing = false; self.refresh()
            if self.quitAfterFinish { DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) } }
        }
        refresh()
    }
    private func suspend() {
        guard armed && !suspended else { return }
        suspended = true
        capture.stop("sleep_or_session_inactive")
        if let writer, !writer.checkpoint() {
            // Do not hold the OS sleep path indefinitely on a slow/full disk.
            writer.enqueue(InputRecord(kind: "boundary", sessionID: capture.sessionID,
                details: "sleep_checkpoint_incomplete; data may remain buffered until wake"))
        }
        refresh()
    }
    private func resume() {
        guard armed && suspended else { return }
        // Session must be unlocked/active; do not resume on a wake notification alone.
        guard suspensionReasons.isEmpty && sessionIsActive() else { return }
        do { try capture.start(); suspended = false }
        catch { fault = "Listener could not resume"; stop(); show("Recording stopped", error.localizedDescription) }
        refresh()
    }
    private func checkHealth() {
        if armed && !sessionIsActive() { suspend() }
        if armed && !CGPreflightListenEventAccess() {
            fault = "Input Monitoring permission lost"; stop()
        } else if armed, let error = writer?.snapshot().lastError {
            fault = "Disk error — recording stopped"; stop(); show("Recording stopped", error)
        } else if armed && !suspended && !capture.checkHealth() {
            fault = "Input listener stopped"; stop(); show("Recording stopped", "macOS disabled the input listener. Check Input Monitoring and turn recording on again.")
        }
        if armed && suspended { resume() }
        refresh()
    }
    private func sessionIsActive() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true && session[kCGSessionOnConsoleKey as String] as? Bool == true
    }
    @objc private func toggleText() {
        guard !armed && !finishing else { return }
        defaults.set(textEnabled, forKey: "omitText"); defaults.set(false, forKey: "acknowledged"); refresh()
    }
    @objc private func toggleTitles() {
        guard !armed && !finishing else { return }
        defaults.set(titlesEnabled, forKey: "omitTitles"); defaults.set(false, forKey: "acknowledged"); refresh()
    }
    @objc private func toggleResume() { defaults.set(!defaults.bool(forKey: "resumeOnLaunch"), forKey: "resumeOnLaunch"); refresh() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { show("Login item", error.localizedDescription) }
        refresh()
    }
    @objc private func openRecordings() {
        let dir = JSONLWriter.Configuration.defaultDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        NSWorkspace.shared.open(dir)
    }
    @objc private func inputPermission() {
        CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc private func contextPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
    @objc private func about() {
        show("Ghost Recorder", "A local data collector for Ghost Typer. macOS 13+. Red REC means collecting; OFF or PAUSED means no input collected. Input Monitoring is required. Accessibility is optional for window titles. No network requests, screenshots, clipboard reads, document scraping, or automatic uploading. Event text may differ from committed IME/autocorrect text. macOS may coalesce pointer events or block protected input. Recordings are plaintext with owner-only permissions, not encrypted. For several days of collection, enable Launch at login and Resume recording when app opens after starting your first session. Public code: github.com/gavinzdarko/ghost-typer-recorder.")
    }
    private func show(_ title: String, _ message: String) {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true); alert.runModal()
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard armed || finishing else { return .terminateNow }
        quitAfterFinish = true
        // Preserve intent for optional explicit resume-on-launch; normal OFF clears it.
        let intent = defaults.bool(forKey: "recordingIntent")
        if armed { stop() }
        defaults.set(intent, forKey: "recordingIntent")
        return .terminateLater
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.setActivationPolicy(.accessory)
app.delegate = delegate
app.run()
