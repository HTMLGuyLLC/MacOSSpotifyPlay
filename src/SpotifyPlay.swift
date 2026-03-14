import Cocoa
import ServiceManagement

// MARK: - Media Key Callback
//
// SAFETY: This callback MUST return fast (<100ms). If it blocks, macOS disables
// the tap and keyboard/mouse input freezes system-wide.
// Rule: no blocking calls, no AppleScript, no locks. Just read data and dispatch.

var suppressNextKeyUp = false

func mediaKeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    // If tap was disabled, let the watchdog handle it — just pass event through
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else { return Unmanaged.passUnretained(event) }
    let delegate = Unmanaged<AppDelegate>.fromOpaque(userInfo).takeUnretainedValue()

    guard delegate.isEnabled else { return Unmanaged.passUnretained(event) }

    guard let nsEvent = NSEvent(cgEvent: event) else {
        return Unmanaged.passUnretained(event)
    }
    guard nsEvent.subtype.rawValue == 8 else {
        return Unmanaged.passUnretained(event)
    }

    let data1 = nsEvent.data1
    let keyCode = (data1 & 0xFFFF0000) >> 16
    let keyState = (data1 & 0xFF00) >> 8

    // 16 = NX_KEYTYPE_PLAY. Ignore everything else.
    guard keyCode == 16 else { return Unmanaged.passUnretained(event) }

    let isKeyDown = keyState == 0x0A
    let isKeyUp = keyState == 0x0B

    if isKeyUp && suppressNextKeyUp {
        suppressNextKeyUp = false
        return nil
    }

    guard isKeyDown else { return Unmanaged.passUnretained(event) }

    // ALWAYS suppress — never let macOS route to Apple Music
    suppressNextKeyUp = true

    let spotifyRunning = NSWorkspace.shared.runningApplications.contains {
        $0.bundleIdentifier == "com.spotify.client"
    }

    if spotifyRunning {
        // Already running — toggle play/pause off main thread.
        // Guard with "is running" so AppleScript doesn't relaunch a quitting Spotify.
        DispatchQueue.global(qos: .userInitiated).async {
            let script = NSAppleScript(source: """
                if application "Spotify" is running then
                    tell application "Spotify" to playpause
                end if
                """)
            var err: NSDictionary?
            script?.executeAndReturnError(&err)
        }
    } else {
        // Not running — launch and auto-play (needs main thread for NSWorkspace)
        DispatchQueue.main.async {
            launchSpotifyAndPlay()
        }
    }
    return nil
}

// MARK: - Launch Spotify & Play

func launchSpotifyAndPlay() {
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false

    guard let spotifyURL = NSWorkspace.shared.urlForApplication(
        withBundleIdentifier: "com.spotify.client"
    ) else { return }

    NSWorkspace.shared.openApplication(at: spotifyURL, configuration: config) { _, error in
        guard error == nil else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            // Wait for process to appear (up to 10s)
            for _ in 0..<40 {
                if NSWorkspace.shared.runningApplications.contains(where: {
                    $0.bundleIdentifier == "com.spotify.client"
                }) { break }
                Thread.sleep(forTimeInterval: 0.25)
            }

            // Poll until Spotify's scripting bridge responds to `play`.
            // Abort immediately if the user closes Spotify during the wait.
            for _ in 0..<40 {
                Thread.sleep(forTimeInterval: 0.5)

                // If user closed Spotify, stop — don't relaunch it
                let stillRunning = NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier == "com.spotify.client"
                }
                guard stillRunning else { return }

                let script = NSAppleScript(source: """
                    if application "Spotify" is running then
                        tell application "Spotify"
                            play
                            return "ok"
                        end tell
                    end if
                    """)
                var err: NSDictionary?
                let result = script?.executeAndReturnError(&err)
                if result?.stringValue == "ok" { return }
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var eventTap: CFMachPort?
    var runLoopSource: CFRunLoopSource?
    var isEnabled = true
    var watchdogTimer: Timer?
    /// Tracks consecutive failures to re-enable the tap
    var tapReenableFailures = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Check accessibility BEFORE doing anything with event taps
        if !checkAccessibility() {
            promptForAccessibility()
            return
        }
        setupMenuBar()
        setupEventTap()
        startWatchdog()
    }

    // MARK: Accessibility Check

    /// Returns true if we have accessibility permission right now.
    func checkAccessibility() -> Bool {
        // This is the standard API — returns current state without prompting
        return AXIsProcessTrusted()
    }

    // MARK: Watchdog
    //
    // Instead of blindly re-enabling the tap forever, we check if we still
    // have accessibility permission. If not, we quit cleanly so we never
    // leave the system in a broken state.

    func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }

            // If accessibility was revoked, quit immediately
            if !self.checkAccessibility() {
                self.tearDownTap()
                NSApp.terminate(nil)
                return
            }

            // Re-enable tap if macOS disabled it (e.g. timeout)
            if let tap = self.eventTap, !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)

                // If it still won't re-enable after a few tries, permission is gone
                if !CGEvent.tapIsEnabled(tap: tap) {
                    self.tapReenableFailures += 1
                    if self.tapReenableFailures >= 3 {
                        self.tearDownTap()
                        NSApp.terminate(nil)
                    }
                } else {
                    self.tapReenableFailures = 0
                }
            }
        }
    }

    /// Cleanly removes the event tap so we never leave a dangling tap
    func tearDownTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    // MARK: Menu Bar

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()

        let menu = NSMenu()

        let enableItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enableItem.target = self
        enableItem.state = .on
        menu.addItem(enableItem)

        menu.addItem(NSMenuItem.separator())

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit SpotifyPlay", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func updateIcon() {
        if let button = statusItem.button {
            if let resourcePath = Bundle.main.path(forResource: "icon", ofType: "png"),
               let img = NSImage(contentsOfFile: resourcePath) {
                img.size = NSSize(width: 18, height: 18)
                img.isTemplate = false
                button.image = img
                button.imagePosition = .imageOnly
                button.image?.isTemplate = false
            } else {
                let symbolName = isEnabled ? "play.circle.fill" : "play.circle"
                if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: "SpotifyPlay") {
                    img.isTemplate = true
                    button.image = img
                }
            }
            button.alphaValue = isEnabled ? 1.0 : 0.4
        }
    }

    @objc func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off
        updateIcon()
    }

    // MARK: Launch at Login

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                    sender.state = .off
                } else {
                    try SMAppService.mainApp.register()
                    sender.state = .on
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not change login item"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    @objc func quit() {
        tearDownTap()
        NSApp.terminate(nil)
    }

    // MARK: Event Tap

    func setupEventTap() {
        let eventMask: CGEventMask = (1 << 14) // NX_SYSDEFINED

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: mediaKeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            promptForAccessibility()
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func promptForAccessibility() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = """
            SpotifyPlay needs Accessibility access to intercept media keys.

            Go to System Settings → Privacy & Security → Accessibility and add SpotifyPlay.

            After granting permission, relaunch the app.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Quit")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            )
        }
        NSApp.terminate(nil)
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
