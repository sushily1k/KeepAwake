import Cocoa
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import UserNotifications

let lowBatteryPercent = 20

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let defaults = UserDefaults.standard
    var systemAssertion = IOPMAssertionID(0)
    var displayAssertion = IOPMAssertionID(0)
    var active = false
    var endDate: Date?          // set for timed sessions
    var watchedApp: String?     // bundle ID, set for "while app runs" sessions
    var timer: Timer?
    var keepDisplayAwake = true
    var lowBatteryCutoff = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: ["keepDisplayAwake": true])
        keepDisplayAwake = defaults.bool(forKey: "keepDisplayAwake")
        lowBatteryCutoff = defaults.bool(forKey: "lowBatteryCutoff")

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // ponytail: polls once a minute; switch to IOPSNotificationCreateRunLoopSource if that ever matters
        Timer.scheduledTimer(timeInterval: 60, target: self, selector: #selector(checkBattery),
                             userInfo: nil, repeats: true).tolerance = 10

        if defaults.bool(forKey: "active") {
            let end = defaults.object(forKey: "endDate") as? Date
            let app = defaults.string(forKey: "watchedApp")
            if let end, end <= Date() { stop() }
            else if let app, !isRunning(app) { stop() }
            else { start(until: end, whileApp: app) }
        }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        releaseAssertions()
    }

    // MARK: Power assertions
    func createAssertions() {
        IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleSystemSleep as CFString,
                                    IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "KeepAwake: prevent system sleep" as CFString,
                                    &systemAssertion)
        if keepDisplayAwake {
            IOPMAssertionCreateWithName(kIOPMAssertPreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "KeepAwake: prevent display sleep" as CFString,
                                        &displayAssertion)
        }
    }

    func releaseAssertions() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }

    // MARK: Session
    func start(until end: Date? = nil, whileApp app: String? = nil) {
        active = true
        endDate = end
        watchedApp = app
        releaseAssertions(); createAssertions()
        timer?.invalidate(); timer = nil
        if let end {
            // Fires late (on wake) if the Mac slept anyway, e.g. lid closed; the session just ends then.
            timer = Timer.scheduledTimer(timeInterval: max(end.timeIntervalSinceNow, 0), target: self,
                                         selector: #selector(timerFired), userInfo: nil, repeats: false)
        }
        if end != nil || app != nil || lowBatteryCutoff {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
        }
        save(); refresh()
        checkBattery()
    }

    /// `reason` is shown as a notification when the session ends on its own.
    func stop(reason: String? = nil) {
        active = false
        endDate = nil
        watchedApp = nil
        timer?.invalidate(); timer = nil
        releaseAssertions()
        save(); refresh()
        if let reason { notify(reason) }
    }

    func save() {
        defaults.set(active, forKey: "active")
        defaults.set(endDate, forKey: "endDate")
        defaults.set(watchedApp, forKey: "watchedApp")
        defaults.set(keepDisplayAwake, forKey: "keepDisplayAwake")
        defaults.set(lowBatteryCutoff, forKey: "lowBatteryCutoff")
    }

    @objc func timerFired() { stop(reason: "Timed session ended. Your Mac can sleep again.") }

    @objc func appTerminated(_ note: Notification) {
        guard let app = watchedApp,
              let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              quit.bundleIdentifier == app, !isRunning(app) else { return }
        stop(reason: "\(quit.localizedName ?? app) quit. Your Mac can sleep again.")
    }

    @objc func checkBattery() {
        guard active, lowBatteryCutoff, let level = batteryLevel(), level < lowBatteryPercent else { return }
        stop(reason: "Battery at \(level)%. Session ended so your Mac can sleep.")
    }

    // MARK: Helpers
    func isRunning(_ bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    func appName(_ bundleID: String) -> String {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.localizedName ?? bundleID
    }

    /// Battery percent while running on battery; nil on AC power or on Macs without a battery.
    func batteryLevel() -> Int? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            return current * 100 / max
        }
        return nil
    }

    func notify(_ body: String) {
        let content = UNMutableNotificationContent()
        content.title = "KeepAwake"
        content.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: Actions
    @objc func statusClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            // Built on demand so the running-apps list and login state are always current.
            statusItem.menu = buildMenu()
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle()
        }
    }

    @objc func toggle() { active ? stop() : start() }

    @objc func startTimed(_ sender: NSMenuItem) {
        start(until: Date().addingTimeInterval(sender.representedObject as! TimeInterval))
    }

    @objc func startWhileApp(_ sender: NSMenuItem) {
        start(whileApp: sender.representedObject as? String)
    }

    @objc func toggleDisplay() {
        keepDisplayAwake.toggle()
        if active { releaseAssertions(); createAssertions() }
        save(); refresh()
    }

    @objc func toggleLowBattery() {
        lowBatteryCutoff.toggle()
        save()
        checkBattery()
    }

    @objc func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() }
            else { try service.register() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
    }

    @objc func quit() { NSApp.terminate(nil) }

    // MARK: UI
    var statusText: String {
        if !active { return "Off" }
        if let endDate { return "On until \(endDate.formatted(date: .omitted, time: .shortened))" }
        if let watchedApp { return "On while \(appName(watchedApp)) runs" }
        return "On indefinitely"
    }

    func refresh() {
        guard let button = statusItem.button else { return }
        let name = active ? "cup.and.saucer.fill" : "cup.and.saucer"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Keep Awake")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Keep Awake: \(statusText)\nClick to toggle, right-click for options"
    }

    func item(_ title: String, _ action: Selector?, on: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        return item
    }

    func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let statusLine = item(statusText, nil)
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(item(active ? "Turn Off" : "Turn On", #selector(toggle)))

        let timedMenu = NSMenu()
        for (label, minutes) in [("15 Minutes", 15), ("30 Minutes", 30), ("1 Hour", 60),
                                 ("2 Hours", 120), ("4 Hours", 240), ("8 Hours", 480)] {
            let entry = item(label, #selector(startTimed(_:)))
            entry.representedObject = TimeInterval(minutes * 60)
            timedMenu.addItem(entry)
        }
        let timedItem = item("Turn On For", nil)
        timedItem.submenu = timedMenu
        menu.addItem(timedItem)

        let appsMenu = NSMenu()
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil
                      && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "") .localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in apps {
            let entry = item(app.localizedName ?? app.bundleIdentifier!, #selector(startWhileApp(_:)),
                             on: active && watchedApp == app.bundleIdentifier)
            entry.representedObject = app.bundleIdentifier
            entry.image = app.icon
            entry.image?.size = NSSize(width: 16, height: 16)
            appsMenu.addItem(entry)
        }
        let appsItem = item("Turn On While App Runs", nil)
        appsItem.submenu = appsMenu
        menu.addItem(appsItem)

        menu.addItem(.separator())
        menu.addItem(item("Keep Display Awake", #selector(toggleDisplay), on: keepDisplayAwake))
        menu.addItem(item("End Session Below \(lowBatteryPercent)% Battery", #selector(toggleLowBattery),
                          on: lowBatteryCutoff))
        menu.addItem(item("Launch at Login", #selector(toggleLaunchAtLogin),
                          on: SMAppService.mainApp.status == .enabled))

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        return menu
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
let delegate = AppDelegate()
app.delegate = delegate
app.run()
