import Cocoa
import LocalAuthentication
import IOKit.pwr_mgt
import IOKit.ps
import ServiceManagement
import ApplicationServices
import Carbon.HIToolbox

// MARK: - System-wide input tap callback

/// Trackpad gesture events have no `CGEventType` cases — AppKit defines them on
/// `NSEvent.EventType` only — but they travel through the same tap and can be matched
/// by raw value. Scroll is included: being able to scroll the documents underneath a
/// lock screen is a hole, not a courtesy.
private let gestureEventRawValues: Set<UInt32> = [
    18, // rotate
    19, // beginGesture
    20, // endGesture
    22, // scrollWheel
    29, // gesture
    30, // magnify
    31, // swipe
    32, // smartMagnify
    34, // pressure (force touch)
    37  // directTouch
]

private func isGestureEvent(_ type: CGEventType) -> Bool {
    gestureEventRawValues.contains(type.rawValue)
}

/// C-compatible callback: while locked we swallow all keyboard + mouse-button
/// events so nothing reaches the apps underneath. The first interaction triggers
/// the Touch ID / password prompt.
private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<AppController>.fromOpaque(refcon).takeUnretainedValue()

    // macOS may disable the tap; re-enable and let the event pass.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = controller.eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return Unmanaged.passUnretained(event)
    }

    // Only the password-fallback path stands the tap down (the system password
    // dialog needs the keyboard we would otherwise swallow). Touch ID does NOT
    // set this, so the tap stays armed for the whole biometric prompt.
    if controller.allowsInputPassthrough {
        return Unmanaged.passUnretained(event)
    }

    switch type {
    case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown:
        DispatchQueue.main.async { controller.requestAuth() }
        return nil // swallow
    case .keyUp, .flagsChanged,
         .leftMouseUp, .rightMouseUp, .otherMouseUp,
         .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
        return nil // swallow
    default:
        // Swallowed silently rather than raising the auth prompt: a stray two-finger
        // brush shouldn't summon Touch ID the way a deliberate click does.
        if controller.blocksGestures, isGestureEvent(type) {
            return nil
        }
        // Cursor movement still passes, so the screen doesn't look frozen.
        return Unmanaged.passUnretained(event)
    }
}

// MARK: - Full-screen lock window

final class LockWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The translucent overlay: dims the screen slightly and shows a low-opacity lock.
/// (Interaction is handled by the event tap; these handlers are a fallback.)
final class LockView: NSView {
    var onUnlockRequest: (() -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onUnlockRequest?() }
    override func keyDown(with event: NSEvent) { onUnlockRequest?() }
}

// MARK: - Power assertions

/// Owns exactly one IOPMAssertion. Acquire/release are idempotent.
///
/// Unlike the raw C call, a failure here is reported rather than swallowed: an
/// assertion that silently failed to take means the Mac sleeps through the very
/// job the user turned this on to protect, with the UI still claiming it's awake.
final class SleepAssertion {
    private let type: CFString
    private let reason: String
    private var id: IOPMAssertionID = 0

    init(type: String, reason: String) {
        self.type = type as CFString
        self.reason = reason
    }

    var isHeld: Bool { id != 0 }

    @discardableResult
    func acquire() -> Bool {
        guard id == 0 else { return true }
        var newID: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(
            type,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &newID
        )
        guard status == kIOReturnSuccess else { return false }
        id = newID
        return true
    }

    func release() {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    deinit { release() }
}

// MARK: - Keep awake

/// Standalone "don't let this Mac sleep" toggle, independent of the screen lock.
///
/// Defaults to PreventUserIdleSystemSleep rather than NoDisplaySleep. The point is
/// that background work keeps running, and that does not require the panel to stay
/// lit — on a laptop the display is the single largest draw, so forcing it on is
/// opt-in via `keepDisplayOn`.
///
/// Note this cannot survive a lid close. macOS forces sleep on clamshell regardless
/// of any assertion (barring true clamshell mode: AC + external display + external
/// input), so neither this nor any other userspace app can promise otherwise.
final class KeepAwakeController {
    enum Duration: Equatable {
        case indefinite
        case minutes(Int)
    }

    private enum Key {
        static let keepDisplayOn = "keepDisplayOn"
        static let lowBatteryCutoff = "lowBatteryCutoff"
        static let batteryFloor = "batteryFloorPercent"
        static let activateOnLaunch = "activateOnLaunch"
    }

    private let defaults = UserDefaults.standard
    private let system = SleepAssertion(
        type: kIOPMAssertionTypeNoIdleSleep, reason: "InsomniacDev: keep awake")
    private let display = SleepAssertion(
        type: kIOPMAssertionTypeNoDisplaySleep, reason: "InsomniacDev: keep display awake")

    private var expiryTimer: Timer?
    private var batteryTimer: Timer?

    private(set) var isActive = false
    private(set) var expiresAt: Date?
    private(set) var lastError: String?

    /// Fired on every state change so the menu bar can redraw itself.
    var onChange: (() -> Void)?

    init() {
        defaults.register(defaults: [
            Key.keepDisplayOn: false,
            Key.lowBatteryCutoff: true,
            Key.batteryFloor: 20,
            Key.activateOnLaunch: false
        ])
    }

    // MARK: Preferences

    var keepDisplayOn: Bool {
        get { defaults.bool(forKey: Key.keepDisplayOn) }
        set {
            defaults.set(newValue, forKey: Key.keepDisplayOn)
            // Apply immediately if a session is already running, so the toggle
            // doesn't appear to do nothing until the next activation.
            if isActive {
                if newValue { display.acquire() } else { display.release() }
            }
            onChange?()
        }
    }

    var lowBatteryCutoff: Bool {
        get { defaults.bool(forKey: Key.lowBatteryCutoff) }
        set {
            defaults.set(newValue, forKey: Key.lowBatteryCutoff)
            if isActive {
                startBatteryWatch()
                enforceBatteryFloor()
            }
            onChange?()
        }
    }

    /// The charge at or below which a running session ends, in percent.
    var batteryFloor: Int {
        get { defaults.integer(forKey: Key.batteryFloor) }
        set {
            defaults.set(newValue, forKey: Key.batteryFloor)
            // Apply at once. Choosing a floor above the current charge and then
            // watching the Mac stay awake for another minute reads as the setting
            // being ignored.
            if isActive { enforceBatteryFloor() }
            onChange?()
        }
    }

    /// Percentages offered in the cutoff picker.
    static let batteryFloorOptions = [10, 15, 20, 25, 30, 40]

    var activateOnLaunch: Bool {
        get { defaults.bool(forKey: Key.activateOnLaunch) }
        set { defaults.set(newValue, forKey: Key.activateOnLaunch); onChange?() }
    }

    // MARK: Activation

    @discardableResult
    func activate(for duration: Duration) -> Bool {
        // Refuse rather than pretend. Turning on below the floor would only trip
        // the cutoff a minute later, which reads as a bug.
        if let blocked = lowBatteryBlock() {
            lastError = blocked
            onChange?()
            return false
        }
        guard system.acquire() else {
            lastError = "The system refused the power assertion."
            onChange?()
            return false
        }
        if keepDisplayOn { display.acquire() }

        isActive = true
        lastError = nil
        scheduleExpiry(duration)
        startBatteryWatch()
        onChange?()
        return true
    }

    func deactivate() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        batteryTimer?.invalidate()
        batteryTimer = nil
        display.release()
        system.release()
        isActive = false
        expiresAt = nil
        onChange?()
    }

    @discardableResult
    func toggle(duration: Duration = .indefinite) -> Bool {
        if isActive {
            deactivate()
            return true
        }
        return activate(for: duration)
    }

    /// Timed sessions end themselves. `.indefinite` clears any pending expiry so
    /// switching from "1 hour" to "indefinitely" doesn't inherit the old deadline.
    private func scheduleExpiry(_ duration: Duration) {
        expiryTimer?.invalidate()
        expiryTimer = nil
        expiresAt = nil

        guard case .minutes(let mins) = duration else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(mins * 60))
        expiresAt = deadline

        let timer = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
            self?.deactivate()
        }
        // .common so it still fires while a menu is tracking the run loop.
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    // MARK: Low-battery cutoff

    private func startBatteryWatch() {
        batteryTimer?.invalidate()
        batteryTimer = nil
        guard lowBatteryCutoff else { return }

        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.enforceBatteryFloor()
        }
        RunLoop.main.add(timer, forMode: .common)
        batteryTimer = timer
    }

    /// End a running session the moment the floor is breached. Driven both by the
    /// minute timer and by changes to the cutoff settings.
    private func enforceBatteryFloor() {
        guard isActive, lowBatteryBlock() != nil else { return }
        let percent = Self.batteryState()?.percent
        lastError = "Keep awake switched off — battery "
            + (percent.map { "at \($0)%" } ?? "at or below \(batteryFloor)%")
            + ", the cutoff is \(batteryFloor)%."
        deactivate()
    }

    /// Non-nil when the low-battery cutoff should prevent or end a session.
    /// Always nil on AC, and on desktop Macs with no battery to read.
    private func lowBatteryBlock() -> String? {
        guard lowBatteryCutoff,
              let state = Self.batteryState(),
              !state.onAC,
              state.percent <= batteryFloor
        else { return nil }
        return "Battery is at \(state.percent)%, at or below the \(batteryFloor)% cutoff."
    }

    /// Charge percentage and whether we're on AC, or nil when there's no battery.
    static func batteryState() -> (percent: Int, onAC: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let desc = IOPSGetPowerSourceDescription(blob, source)?
                    .takeUnretainedValue() as? [String: Any],
                  let current = desc[kIOPSCurrentCapacityKey] as? Int,
                  let capacity = desc[kIOPSMaxCapacityKey] as? Int, capacity > 0
            else { continue }
            let onAC = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            return (Int((Double(current) / Double(capacity) * 100).rounded()), onAC)
        }
        return nil
    }

    // MARK: Display strings

    /// "42 minutes left" / "1h 20m left", or nil for an indefinite session.
    var remainingDescription: String? {
        guard let expiresAt else { return nil }
        let seconds = max(0, Int(expiresAt.timeIntervalSinceNow.rounded()))
        let minutes = (seconds + 59) / 60
        if minutes < 60 { return "\(minutes) min left" }
        return "\(minutes / 60)h \(minutes % 60)m left"
    }

    var statusSummary: String {
        guard isActive else { return "InsomniacDev — click for the menu, double-click to lock" }
        return "Keeping awake" + (remainingDescription.map { " · \($0)" } ?? " · no time limit")
    }
}

// MARK: - Global hot key

/// C-compatible Carbon handler. Every hot key the process registers lands here,
/// so the signature is checked before acting.
private func hotKeyHandler(
    callRef: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData = userData else { return noErr }

    var id = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &id
    )
    guard status == noErr, id.signature == HotKeyController.signature else { return noErr }

    let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async { controller.onTrigger?() }
    return noErr
}

/// The system-wide shortcut that locks the screen.
///
/// Carbon rather than `NSEvent.addGlobalMonitorForEvents` for two reasons: a global
/// monitor needs Accessibility access, which would mean demanding that permission at
/// launch instead of at the first lock, and it only *observes* — the keystroke would
/// still reach whatever app is in front. `RegisterEventHotKey` needs no permission
/// and consumes the event.
final class HotKeyController {
    struct Shortcut {
        let id: String
        let title: String                       // "⌃⌘L", as shown in the menu
        let keyCode: UInt32
        let carbonModifiers: UInt32
        let keyEquivalent: String               // for the menu item's own display
        let cocoaModifiers: NSEvent.ModifierFlags
    }

    static let signature: OSType = 0x4C4B_5220  // 'LKR '
    static let offID = "off"

    /// A fixed set rather than a key recorder: four variants of the same letter cover
    /// the realistic conflicts, and a recorder is a lot of UI for one shortcut.
    static let options: [Shortcut] = [
        Shortcut(id: "ctrl-cmd-l", title: "⌃⌘L",
                 keyCode: UInt32(kVK_ANSI_L),
                 carbonModifiers: UInt32(controlKey | cmdKey),
                 keyEquivalent: "l", cocoaModifiers: [.control, .command]),
        Shortcut(id: "opt-cmd-l", title: "⌥⌘L",
                 keyCode: UInt32(kVK_ANSI_L),
                 carbonModifiers: UInt32(optionKey | cmdKey),
                 keyEquivalent: "l", cocoaModifiers: [.option, .command]),
        Shortcut(id: "ctrl-shift-l", title: "⌃⇧L",
                 keyCode: UInt32(kVK_ANSI_L),
                 carbonModifiers: UInt32(controlKey | shiftKey),
                 keyEquivalent: "l", cocoaModifiers: [.control, .shift]),
        Shortcut(id: "ctrl-opt-cmd-l", title: "⌃⌥⌘L",
                 keyCode: UInt32(kVK_ANSI_L),
                 carbonModifiers: UInt32(controlKey | optionKey | cmdKey),
                 keyEquivalent: "l", cocoaModifiers: [.control, .option, .command])
    ]

    private enum Key {
        static let shortcut = "lockShortcut"
    }

    private let defaults = UserDefaults.standard
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Non-nil when the chosen shortcut could not be claimed, so the menu can say so
    /// instead of showing a checked item that does nothing.
    private(set) var lastError: String?

    var onTrigger: (() -> Void)?

    init() {
        defaults.register(defaults: [Key.shortcut: Self.options[0].id])
    }

    /// The persisted selection; `nil` once the user turns the shortcut off.
    var current: Shortcut? {
        let id = defaults.string(forKey: Key.shortcut) ?? Self.options[0].id
        return Self.options.first { $0.id == id }
    }

    /// True when the shortcut is both chosen and actually claimed from the system.
    var isRegistered: Bool { hotKeyRef != nil }

    /// (Re)claim the current selection. Safe to call repeatedly.
    @discardableResult
    func apply() -> Bool {
        unregister()
        lastError = nil

        guard let shortcut = current else { return true }

        guard installHandler() else {
            lastError = "The system refused to install the shortcut handler."
            return false
        }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            id,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref = ref else {
            // Far and away the common case: something else already owns the combo.
            lastError = status == eventHotKeyExistsErr
                ? "\(shortcut.title) is already used by another app or by macOS."
                : "The system refused \(shortcut.title) (error \(status))."
            return false
        }
        hotKeyRef = ref
        return true
    }

    /// Persist a selection and claim it. Pass `offID` to disable the shortcut.
    @discardableResult
    func select(_ id: String) -> Bool {
        defaults.set(id, forKey: Key.shortcut)
        return apply()
    }

    private func installHandler() -> Bool {
        guard handlerRef == nil else { return true }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // GetEventDispatcherTarget, not GetApplicationEventTarget. Apple's own hot-key
        // sample uses the application target, but that's a Carbon-app assumption: under
        // NSApplication's run loop the press never reaches a handler installed there.
        // Measured — a handler on the application target saw nothing while one on the
        // dispatcher target fired for the same keystroke.
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        return status == noErr
    }

    private func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
    }

    deinit {
        unregister()
        if let handler = handlerRef { RemoveEventHandler(handler) }
    }
}

// MARK: - Controller

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lockWindows: [LockWindow] = []

    /// Held only while the shield is up, so the screen the user is standing in
    /// front of doesn't dim mid-session. Deliberately a separate assertion from
    /// `keepAwake` — unlocking must never tear down a keep-awake session the user
    /// switched on themselves.
    private let lockAssertion = SleepAssertion(
        type: kIOPMAssertionTypeNoDisplaySleep, reason: "InsomniacDev: screen locked")
    let keepAwake = KeepAwakeController()
    let hotKey = HotKeyController()

    private(set) var isLocked = false
    private(set) var isAuthenticating = false

    /// Set ONLY by the password fallback, which cannot work with the tap armed.
    /// Kept separate from `isAuthenticating` so the biometric path never opens
    /// the machine up: previously any auth attempt disabled input blocking.
    private(set) var allowsInputPassthrough = false

    private var authContext: LAContext?
    private var authWatchdog: Timer?
    private var hintLabels: [NSTextField] = []

    /// Pending single-click menu, cancelled if the click turns out to be a double.
    private var menuTimer: Timer?

    private enum LockKey {
        static let blockGestures = "blockGestures"
    }

    /// Whether the shield also swallows trackpad gestures. Read by the tap callback on
    /// every event, so toggling it takes effect mid-lock — the gesture types are always
    /// in the tap's mask (a mask can't be changed after the tap is created) and the
    /// decision to swallow is made per event.
    var blocksGestures: Bool {
        get { UserDefaults.standard.bool(forKey: LockKey.blockGestures) }
        set { UserDefaults.standard.set(newValue, forKey: LockKey.blockGestures) }
    }

    // Input tap state (read by the C callback, so not private).
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Blocking is the default: a lock that lets you swipe between Spaces or scroll
        // the window underneath isn't locking much.
        UserDefaults.standard.register(defaults: [LockKey.blockGestures: true])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        keepAwake.onChange = { [weak self] in self?.refreshStatusItem() }
        refreshStatusItem()

        hotKey.onTrigger = { [weak self] in self?.lock() }
        // No alert if this fails: an app that launches at login must not greet the
        // user with a modal. The menu carries the warning instead.
        hotKey.apply()

        if keepAwake.activateOnLaunch {
            keepAwake.activate(for: .indefinite)
        }
    }

    /// The icon is the only feedback that keep-awake is on, so it has to reflect
    /// state: an open eye while awake, the lock otherwise. Deliberately not the coffee
    /// cup every other caffeine app uses — and not a bolt or a moon either, both of
    /// which already mean something else in the menu bar (charging, Focus).
    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        let symbol = keepAwake.isActive ? "eye.fill" : "lock.fill"
        let label = keepAwake.isActive ? "Keeping awake" : "Lock"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        button.image = image
        button.toolTip = keepAwake.statusSummary
    }

    // MARK: Menu bar interaction

    @objc private func statusClicked() {
        guard let event = NSApp.currentEvent else { showMenu(); return }

        // Right-click still opens the menu with no delay — there's no double-right-click
        // gesture to wait for.
        if event.type == .rightMouseUp {
            cancelPendingMenu()
            showMenu()
            return
        }

        if event.clickCount >= 2 {
            cancelPendingMenu()
            lock()
            return
        }

        // Single click: hold the menu back just long enough to see whether a second
        // click is coming. An NSMenu runs its own tracking loop, so opening it
        // immediately would swallow that second click and make double-click-to-lock
        // unreachable.
        //
        // Capped well below the system interval (commonly 0.5s), which is tuned for
        // not misreading two deliberate clicks — far more patience than a menu should
        // ask for. Real double-clicks land in 100-200ms, so 0.25s catches them while
        // keeping the menu feeling immediate.
        cancelPendingMenu()
        let delay = min(NSEvent.doubleClickInterval, 0.25)
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            self?.menuTimer = nil
            self?.showMenu()
        }
        RunLoop.main.add(timer, forMode: .common)
        menuTimer = timer
    }

    private func cancelPendingMenu() {
        menuTimer?.invalidate()
        menuTimer = nil
    }

    /// Minutes offered in the Duration submenu. 0 means "no time limit".
    private static let durations: [(title: String, minutes: Int)] = [
        ("Indefinitely", 0),
        ("5 minutes", 5),
        ("15 minutes", 15),
        ("1 hour", 60),
        ("2 hours", 120),
        ("5 hours", 300)
    ]

    private func showMenu() {
        let menu = NSMenu()

        let lockItem = NSMenuItem(title: "Lock Screen", action: #selector(lock), keyEquivalent: "")
        lockItem.target = self
        // Advertise the real global shortcut, and only while it is actually claimed —
        // a key equivalent we don't own would be a promise the app can't keep.
        if let shortcut = hotKey.current, hotKey.isRegistered {
            lockItem.keyEquivalent = shortcut.keyEquivalent
            lockItem.keyEquivalentModifierMask = shortcut.cocoaModifiers
        }
        menu.addItem(lockItem)

        menu.addItem(shortcutMenuItem())

        let gestureItem = NSMenuItem(
            title: "Block Trackpad Gestures", action: #selector(toggleBlockGestures), keyEquivalent: "")
        gestureItem.target = self
        gestureItem.state = blocksGestures ? .on : .off
        gestureItem.toolTip =
            "Also swallow scrolling, pinch, rotate and swipe while locked. "
            + "Mission Control and Spaces switching are handled by the system and may get through."
        menu.addItem(gestureItem)

        menu.addItem(.separator())

        let awakeItem = NSMenuItem(
            title: "Keep Awake", action: #selector(toggleKeepAwake), keyEquivalent: "k")
        awakeItem.target = self
        awakeItem.state = keepAwake.isActive ? .on : .off
        menu.addItem(awakeItem)

        // Only meaningful while a session is running, so it doubles as the
        // countdown readout rather than sitting there empty.
        if keepAwake.isActive {
            let status = NSMenuItem(
                title: "  " + (keepAwake.remainingDescription ?? "No time limit"),
                action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }

        // A cutoff that fired ends the session leaving no other trace — without this
        // the Mac just quietly stops being held awake.
        if !keepAwake.isActive, let error = keepAwake.lastError {
            let warning = NSMenuItem(title: "  ⚠︎ " + error, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            menu.addItem(warning)
        }

        let durationItem = NSMenuItem(title: "Start For", action: nil, keyEquivalent: "")
        let durationMenu = NSMenu()
        for (title, minutes) in Self.durations {
            let item = NSMenuItem(
                title: title, action: #selector(startForDuration(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            durationMenu.addItem(item)
        }
        durationItem.submenu = durationMenu
        menu.addItem(durationItem)

        menu.addItem(.separator())

        let displayItem = NSMenuItem(
            title: "Also Keep Display On", action: #selector(toggleKeepDisplayOn), keyEquivalent: "")
        displayItem.target = self
        displayItem.state = keepAwake.keepDisplayOn ? .on : .off
        displayItem.toolTip =
            "Off by default: work keeps running with the screen dark, which saves battery."
        menu.addItem(displayItem)

        menu.addItem(batteryCutoffMenuItem())

        let onLaunchItem = NSMenuItem(
            title: "Keep Awake On Launch", action: #selector(toggleActivateOnLaunch), keyEquivalent: "")
        onLaunchItem.target = self
        onLaunchItem.state = keepAwake.activateOnLaunch ? .on : .off
        menu.addItem(onLaunchItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = launchesAtLogin ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit InsomniacDev", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// "Lock Shortcut ▸" — the choices, plus whatever went wrong claiming one.
    private func shortcutMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Lock Shortcut", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentID = hotKey.current?.id

        for shortcut in HotKeyController.options {
            let option = NSMenuItem(
                title: shortcut.title, action: #selector(selectShortcut(_:)), keyEquivalent: "")
            option.target = self
            option.representedObject = shortcut.id
            option.state = shortcut.id == currentID ? .on : .off
            submenu.addItem(option)
        }

        let offItem = NSMenuItem(
            title: "Off", action: #selector(selectShortcut(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.representedObject = HotKeyController.offID
        offItem.state = currentID == nil ? .on : .off
        submenu.addItem(.separator())
        submenu.addItem(offItem)

        // A shortcut another app already owns fails silently at launch. Say so here,
        // or the checked item looks like it works.
        if let error = hotKey.lastError {
            submenu.addItem(.separator())
            let warning = NSMenuItem(title: "⚠︎ " + error, action: nil, keyEquivalent: "")
            warning.isEnabled = false
            submenu.addItem(warning)
        }

        item.submenu = submenu
        return item
    }

    @objc private func selectShortcut(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        // Failure is worth an alert here — unlike at launch, the user just asked for
        // this and would otherwise watch the checkmark move onto a dead shortcut.
        if !hotKey.select(id), let message = hotKey.lastError {
            let alert = NSAlert()
            alert.messageText = "Couldn't set the lock shortcut"
            alert.informativeText = message
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func toggleBlockGestures() {
        blocksGestures.toggle()
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: Keep-awake actions

    @objc private func toggleKeepAwake() {
        if !keepAwake.toggle() { reportKeepAwakeFailure() }
    }

    @objc private func startForDuration(_ sender: NSMenuItem) {
        let duration: KeepAwakeController.Duration =
            sender.tag == 0 ? .indefinite : .minutes(sender.tag)
        // Re-activate rather than toggle: picking a duration while already running
        // should reset the clock, not switch the session off.
        keepAwake.deactivate()
        if !keepAwake.activate(for: duration) { reportKeepAwakeFailure() }
    }

    @objc private func toggleKeepDisplayOn() {
        keepAwake.keepDisplayOn.toggle()
    }

    /// "Low Battery Cutoff: 20% ▸" — off, or the charge to stop at. The title carries
    /// the current setting so it's readable without opening the submenu.
    private func batteryCutoffMenuItem() -> NSMenuItem {
        let enabled = keepAwake.lowBatteryCutoff
        let item = NSMenuItem(
            title: "Low Battery Cutoff: " + (enabled ? "\(keepAwake.batteryFloor)%" : "Off"),
            action: nil, keyEquivalent: "")

        let submenu = NSMenu()
        let offItem = NSMenuItem(
            title: "Off", action: #selector(selectBatteryFloor(_:)), keyEquivalent: "")
        offItem.target = self
        offItem.tag = 0
        offItem.state = enabled ? .off : .on
        submenu.addItem(offItem)
        submenu.addItem(.separator())

        for percent in KeepAwakeController.batteryFloorOptions {
            let option = NSMenuItem(
                title: "\(percent)%", action: #selector(selectBatteryFloor(_:)), keyEquivalent: "")
            option.target = self
            option.tag = percent
            option.state = (enabled && percent == keepAwake.batteryFloor) ? .on : .off
            submenu.addItem(option)
        }

        // Only meaningful on a machine with a battery, and only informative while
        // it's the one supplying power.
        if let state = KeepAwakeController.batteryState() {
            submenu.addItem(.separator())
            let now = NSMenuItem(
                title: "  Now: \(state.percent)%" + (state.onAC ? " (on power)" : ""),
                action: nil, keyEquivalent: "")
            now.isEnabled = false
            submenu.addItem(now)
        }

        item.submenu = submenu
        return item
    }

    @objc private func selectBatteryFloor(_ sender: NSMenuItem) {
        if sender.tag == 0 {
            keepAwake.lowBatteryCutoff = false
        } else {
            // Floor first: enabling the cutoff enforces it immediately, and it should
            // enforce the percentage the user just picked, not the previous one.
            keepAwake.batteryFloor = sender.tag
            keepAwake.lowBatteryCutoff = true
        }
    }

    @objc private func toggleActivateOnLaunch() {
        keepAwake.activateOnLaunch.toggle()
    }

    /// A refused assertion is invisible otherwise — the user would think the Mac
    /// was being held awake when it wasn't.
    private func reportKeepAwakeFailure() {
        guard let message = keepAwake.lastError else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't keep the Mac awake"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: Launch at login

    private var launchesAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    @objc private func toggleLaunchAtLogin() {
        do {
            if launchesAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    // MARK: Locking

    @objc private func lock() {
        guard !isLocked else { return }

        // We need Accessibility permission to block input. Bail early (with a
        // prompt) rather than showing a lock that doesn't actually block.
        guard ensureAccessibilityPermission() else { return }

        isLocked = true
        lockAssertion.acquire()

        for screen in NSScreen.screens {
            let window = LockWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false
            )
            window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: true)

            let view = LockView(frame: screen.frame)
            view.wantsLayer = true
            view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.20).cgColor
            view.onUnlockRequest = { [weak self] in self?.requestAuth() }
            addLockChrome(to: view, screenSize: screen.frame.size)

            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            lockWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)

        // Fail closed. A shield we cannot back with a live tap is worse than no lock
        // at all: it looks secure while every keystroke reaches the apps underneath.
        guard installEventTap() else {
            NSSound.beep()
            unlock()
            return
        }
    }

    private static let defaultHint = "Locked — click or press any key to unlock"

    private func addLockChrome(to view: NSView, screenSize: NSSize) {
        let config = NSImage.SymbolConfiguration(pointSize: 120, weight: .thin)
        let lockImage = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")?
            .withSymbolConfiguration(config)

        let imageView = NSImageView(image: lockImage ?? NSImage())
        imageView.contentTintColor = NSColor.white.withAlphaComponent(0.35)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)

        let hint = NSTextField(labelWithString: Self.defaultHint)
        hint.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.45)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        hintLabels.append(hint)

        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -20),
            hint.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            hint.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 24)
        ])
    }

    private func unlock() {
        guard isLocked else { return }
        isLocked = false
        authWatchdog?.invalidate()
        authWatchdog = nil
        authContext = nil
        isAuthenticating = false
        allowsInputPassthrough = false
        removeEventTap()
        for window in lockWindows { window.orderOut(nil) }
        lockWindows.removeAll()
        hintLabels.removeAll()
        lockAssertion.release()
    }

    // MARK: Input tap

    @discardableResult
    private func installEventTap() -> Bool {
        let types: [CGEventType] = [
            .keyDown, .keyUp, .flagsChanged,
            .leftMouseDown, .leftMouseUp,
            .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp,
            .leftMouseDragged, .rightMouseDragged, .otherMouseDragged
        ]
        var mask: CGEventMask = 0
        for type in types {
            mask |= (CGEventMask(1) << CGEventMask(type.rawValue))
        }
        // Always tapped, whatever the preference says. The mask is fixed at creation,
        // so subscribing here is what lets the toggle apply to a lock already up; the
        // callback passes them straight through when blocking is off.
        for raw in gestureEventRawValues {
            mask |= (CGEventMask(1) << CGEventMask(raw))
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: refcon
        ) else {
            // Shouldn't happen once permission is granted, but report it so the
            // caller can fail closed rather than show a shield that blocks nothing.
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap
        runLoopSource = source
        return true
    }

    private func removeEventTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    // MARK: Authentication

    func requestAuth() {
        guard isLocked, !isAuthenticating else { return }

        let context = LAContext()
        context.localizedCancelTitle = "Stay Locked"
        let reason = "Unlock your screen"

        // Preferred path: Touch ID. The sensor is read by the Secure Enclave, not
        // through the event stream, so the tap can stay armed and the shield can
        // stay up for the whole prompt — the screen is never actually unblocked.
        //
        // Note this is .deviceOwnerAuthenticationWithBiometrics, NOT
        // .deviceOwnerAuthentication: the latter silently falls back to a password
        // field, which would need the very keyboard the tap is swallowing. Using
        // the biometrics-only policy means no code path can deadlock on that.
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) {
            isAuthenticating = true
            authContext = context

            // Drop the shield one level so the system prompt is visible above it.
            // Input stays blocked by the tap regardless of window level, so this
            // cannot reproduce the old click-through deadlock. Even if the prompt
            // ends up obscured, the hint below tells the user what to do and the
            // sensor works whether or not its dialog is on screen.
            lowerOverlayBelowDialog()
            setHint("Touch ID to unlock")
            startAuthWatchdog(context)

            context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics,
                                   localizedReason: reason) { [weak self] success, _ in
                DispatchQueue.main.async { self?.finishAuth(success: success) }
            }
            return
        }

        // Fallback: no biometrics — a Mac without Touch ID, or biometry locked out
        // after repeated failures. The system password dialog genuinely needs the
        // keyboard, so this is the one path where the tap must stand down. The
        // watchdog re-arms the lock if the user walks away instead of answering,
        // rather than leaving the machine open indefinitely.
        var policyError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError) else {
            NSSound.beep()
            return
        }

        isAuthenticating = true
        allowsInputPassthrough = true
        authContext = context
        hideOverlay()
        startAuthWatchdog(context)

        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { [weak self] success, _ in
            DispatchQueue.main.async { self?.finishAuth(success: success) }
        }
    }

    /// Single exit point for both auth paths. Idempotent: cancelling a context makes
    /// the evaluate callback fire too, so this can legitimately be reached twice.
    private func finishAuth(success: Bool) {
        guard isAuthenticating else { return }

        authWatchdog?.invalidate()
        authWatchdog = nil
        authContext = nil
        isAuthenticating = false
        allowsInputPassthrough = false

        if success {
            unlock()
        } else {
            NSSound.beep()
            // Cancelled, failed, or timed out — re-arm the shield, stay locked.
            showOverlay()
        }
    }

    /// If the auth prompt is never answered, cancel it and return to a fully locked
    /// state. Without this the password fallback would sit with input passing
    /// through for as long as the dialog was ignored.
    private func startAuthWatchdog(_ context: LAContext) {
        authWatchdog?.invalidate()
        let timer = Timer(timeInterval: 30, repeats: false) { [weak self] _ in
            context.invalidate()
            DispatchQueue.main.async { self?.finishAuth(success: false) }
        }
        // .common so it still fires while a modal system dialog owns the run loop.
        RunLoop.main.add(timer, forMode: .common)
        authWatchdog = timer
    }

    /// Order the lock windows off-screen so nothing sits above the auth dialog.
    private func hideOverlay() {
        for window in lockWindows { window.orderOut(nil) }
    }

    /// Re-raise the shield to the top-most level and bring it back to the front.
    private func showOverlay() {
        let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        for window in lockWindows {
            window.level = level
            window.makeKeyAndOrderFront(nil)
        }
        setHint(Self.defaultHint)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Keep the shield visible but just below the system auth dialog. Safe because
    /// the tap blocks input independently of window level.
    private func lowerOverlayBelowDialog() {
        let level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) - 1)
        for window in lockWindows { window.level = level }
    }

    private func setHint(_ text: String) {
        for label in hintLabels { label.stringValue = text }
    }

    // MARK: Accessibility permission

    @discardableResult
    private func ensureAccessibilityPermission() -> Bool {
        if AXIsProcessTrusted() { return true }

        // Prompt macOS to open the grant sheet.
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)

        let alert = NSAlert()
        alert.messageText = "Accessibility permission needed"
        alert.informativeText = """
        To block the keyboard and mouse while locked, InsomniacDev needs Accessibility access.

        Open System Settings ▸ Privacy & Security ▸ Accessibility, enable “InsomniacDev”, \
        then click the menu bar lock again.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
        return false
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
