import Cocoa
import LocalAuthentication
import IOKit.pwr_mgt
import ApplicationServices

// MARK: - System-wide input tap callback

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
        // Let cursor movement / scroll through so the screen still feels alive.
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

// MARK: - Controller

final class AppController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var lockWindows: [LockWindow] = []
    private var sleepAssertionID: IOPMAssertionID = 0
    private(set) var isLocked = false
    private(set) var isAuthenticating = false

    /// Set ONLY by the password fallback, which cannot work with the tap armed.
    /// Kept separate from `isAuthenticating` so the biometric path never opens
    /// the machine up: previously any auth attempt disabled input blocking.
    private(set) var allowsInputPassthrough = false

    private var authContext: LAContext?
    private var authWatchdog: Timer?
    private var hintLabels: [NSTextField] = []

    // Input tap state (read by the C callback, so not private).
    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // MARK: App lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Lock")
            img?.isTemplate = true
            button.image = img
            button.target = self
            button.action = #selector(statusClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    // MARK: Menu bar interaction

    @objc private func statusClicked() {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showMenu()
        } else {
            lock()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let lockItem = NSMenuItem(title: "Lock Screen", action: #selector(lock), keyEquivalent: "l")
        lockItem.target = self
        menu.addItem(lockItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Locker", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quit() { NSApplication.shared.terminate(nil) }

    // MARK: Locking

    @objc private func lock() {
        guard !isLocked else { return }

        // We need Accessibility permission to block input. Bail early (with a
        // prompt) rather than showing a lock that doesn't actually block.
        guard ensureAccessibilityPermission() else { return }

        isLocked = true
        keepAwake(true)

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
        keepAwake(false)
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
        To block the keyboard and mouse while locked, Locker needs Accessibility access.

        Open System Settings ▸ Privacy & Security ▸ Accessibility, enable “Locker”, \
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

    // MARK: Keep display awake

    private func keepAwake(_ on: Bool) {
        if on {
            guard sleepAssertionID == 0 else { return }
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Locker: screen locked" as CFString,
                &sleepAssertionID
            )
        } else if sleepAssertionID != 0 {
            IOPMAssertionRelease(sleepAssertionID)
            sleepAssertionID = 0
        }
    }
}

// MARK: - Bootstrap

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
