import Cocoa

/// Monitors global key events and reports them through `onKeyPress`.
/// Uses both CGEvent tap and NSEvent global monitor for maximum compatibility.
///
/// Intentionally self-contained: it knows nothing about effects or the host app.
/// Captured keystrokes are mapped to a (row, col) on the keyboard plus an optional
/// A–Z glyph and handed to `onKeyPress`. Nothing is stored or transmitted — this
/// file is the entire surface that touches your keys.
public final class KeyboardMonitor {
    // macOS virtual key code -> (row, col) on the Ornata V2
    static let vkToMatrix: [Int: (Int, Int)] = [
        0x35:(0,1), 0x7A:(0,3), 0x78:(0,4), 0x63:(0,5), 0x76:(0,6),
        0x60:(0,7), 0x61:(0,8), 0x62:(0,9), 0x64:(0,10), 0x65:(0,11),
        0x6D:(0,12), 0x67:(0,13), 0x6F:(0,14),
        0x32:(1,1), 0x12:(1,2), 0x13:(1,3), 0x14:(1,4), 0x15:(1,5),
        0x17:(1,6), 0x16:(1,7), 0x1A:(1,8), 0x1C:(1,9), 0x19:(1,10),
        0x1D:(1,11), 0x1B:(1,12), 0x18:(1,13), 0x33:(1,14), 0x72:(1,15),
        0x73:(1,16), 0x74:(1,17), 0x47:(1,18), 0x4B:(1,19), 0x43:(1,20),
        0x4E:(1,21),
        0x30:(2,1), 0x0C:(2,2), 0x0D:(2,3), 0x0E:(2,4), 0x0F:(2,5),
        0x11:(2,6), 0x10:(2,7), 0x20:(2,8), 0x22:(2,9), 0x1F:(2,10),
        0x23:(2,11), 0x21:(2,12), 0x1E:(2,13), 0x2A:(2,14), 0x75:(2,15),
        0x77:(2,16), 0x79:(2,17), 0x59:(2,18), 0x5B:(2,19), 0x5C:(2,20),
        0x45:(2,21),
        0x39:(3,1), 0x00:(3,2), 0x01:(3,3), 0x02:(3,4), 0x03:(3,5),
        0x05:(3,6), 0x04:(3,7), 0x26:(3,8), 0x28:(3,9), 0x25:(3,10),
        0x29:(3,11), 0x27:(3,12), 0x24:(3,14), 0x56:(3,18), 0x57:(3,19),
        0x58:(3,20),
        0x38:(4,1), 0x06:(4,3), 0x07:(4,4), 0x08:(4,5), 0x09:(4,6),
        0x0B:(4,7), 0x2D:(4,8), 0x2E:(4,9), 0x2B:(4,10), 0x2F:(4,11),
        0x2C:(4,12), 0x3C:(4,14), 0x7E:(4,16), 0x53:(4,18), 0x54:(4,19),
        0x55:(4,20), 0x4C:(4,21),
        0x3B:(5,1), 0x3A:(5,2), 0x37:(5,3), 0x31:(5,7), 0x3D:(5,11),
        0x36:(5,13), 0x3E:(5,14), 0x7B:(5,15), 0x7D:(5,16), 0x7C:(5,17),
        0x52:(5,19), 0x41:(5,20),
    ]

    private var eventTap: CFMachPort?
    private var tapThread: Thread?
    private var globalMonitor: Any?

    /// Invoked on every mapped key press with (row, col, optional A–Z glyph).
    /// The host app wires this to its effect engine; this library never stores
    /// or forwards keystrokes anywhere else.
    public var onKeyPress: ((Int, Int, Character?) -> Void)?

    // All mutable state accessed from multiple threads is protected by this lock
    private let lock = NSLock()
    private var _tapRunLoop: CFRunLoop?
    private var _activeSource: String?
    private var _eventCount = 0
    private var _receivingEvents = false

    public init() {}

    public var hasAccessibilityPermission: Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: false] as CFDictionary)
    }

    /// Whether key events are actually being received (set after first event)
    public var receivingEvents: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _receivingEvents
    }

    @discardableResult
    public func start() -> Bool {
        guard eventTap == nil && globalMonitor == nil else {
            NSLog("RizlDizl: keyboard monitor already running")
            return true
        }

        NSLog("RizlDizl: starting keyboard monitor, accessibility=%d", hasAccessibilityPermission ? 1 : 0)

        // Strategy 1: CGEvent tap on a dedicated thread
        let tapStarted = startEventTap()

        // Strategy 2: NSEvent global monitor (works with Accessibility permission on newer macOS)
        let monitorStarted = startGlobalMonitor()

        NSLog("RizlDizl: eventTap=%d, globalMonitor=%d", tapStarted ? 1 : 0, monitorStarted ? 1 : 0)
        return tapStarted || monitorStarted
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        lock.lock()
        let rl = _tapRunLoop
        _tapRunLoop = nil
        _receivingEvents = false
        _activeSource = nil
        _eventCount = 0
        lock.unlock()

        if let rl = rl {
            CFRunLoopStop(rl)
        }
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        eventTap = nil
        tapThread = nil
        globalMonitor = nil
    }

    // MARK: - CGEvent tap (works when Input Monitoring is granted)

    private func startEventTap() -> Bool {
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .tailAppendEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo = userInfo else { return nil }
                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    NSLog("RizlDizl: event tap disabled (type=%d), re-enabling", type.rawValue)
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    // Reset active source so the NSEvent monitor can take over
                    // if the tap keeps getting disabled
                    monitor.lock.lock()
                    monitor._activeSource = nil
                    monitor.lock.unlock()
                    return nil
                }

                if type == .keyDown {
                    let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
                    let glyph = monitor.normalizedLetter(fromCGEvent: event)
                    monitor.handleKeyCode(keyCode, glyph: glyph, source: "tap")
                }
                return nil
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("RizlDizl: CGEvent.tapCreate FAILED")
            return false
        }

        eventTap = tap

        let thread = Thread { [weak self] in
            guard let self = self else { return }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            let rl = CFRunLoopGetCurrent()!
            self.lock.lock()
            self._tapRunLoop = rl
            self.lock.unlock()
            CFRunLoopAddSource(rl, source, .defaultMode)
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("RizlDizl: event tap thread running")
            CFRunLoopRun()
        }
        thread.name = "RizlDizl.eventTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
        return true
    }

    // MARK: - NSEvent global monitor (alternative for macOS 15+)

    private func startGlobalMonitor() -> Bool {
        let monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let glyph = self?.normalizedLetter(fromNSEvent: event)
            self?.handleKeyCode(Int(event.keyCode), glyph: glyph, source: "nsEvent")
        }
        if let monitor = monitor {
            globalMonitor = monitor
            NSLog("RizlDizl: NSEvent global monitor installed")
            return true
        }
        NSLog("RizlDizl: NSEvent global monitor FAILED")
        return false
    }

    // MARK: - Event handling

    private func normalizedLetter(fromNSEvent event: NSEvent) -> Character? {
        normalizedLetter(fromString: event.characters)
    }

    private func normalizedLetter(fromCGEvent event: CGEvent) -> Character? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(
            maxStringLength: buffer.count,
            actualStringLength: &length,
            unicodeString: &buffer
        )
        guard length > 0 else { return nil }
        let string = String(utf16CodeUnits: buffer, count: length)
        return normalizedLetter(fromString: string)
    }

    private func normalizedLetter(fromString string: String?) -> Character? {
        guard let raw = string?.first else { return nil }
        let upper = String(raw).uppercased()
        guard upper.count == 1, let scalar = upper.unicodeScalars.first else { return nil }
        guard scalar.value >= 65 && scalar.value <= 90 else { return nil }
        return Character(upper)
    }

    private func handleKeyCode(_ keyCode: Int, glyph: Character?, source: String) {
        lock.lock()

        // If both CGEvent tap and NSEvent monitor work, use whichever fires first
        // and suppress the other to avoid double-triggering
        let isNewSource = _activeSource == nil
        if isNewSource {
            _activeSource = source
        }
        guard _activeSource == source else {
            lock.unlock()
            return
        }

        _eventCount += 1
        _receivingEvents = true
        let count = _eventCount
        lock.unlock()

        // Log outside the lock to avoid holding it during I/O
        if isNewSource {
            NSLog("RizlDizl: using %@ for key events", source)
        }
        if count <= 5 {
            NSLog("RizlDizl: key #%d vk=0x%02X mapped=%d glyph=%@ via %@",
                  count, keyCode,
                  KeyboardMonitor.vkToMatrix[keyCode] != nil ? 1 : 0,
                  glyph.map(String.init) ?? "-", source)
        }
        if let (row, col) = KeyboardMonitor.vkToMatrix[keyCode] {
            onKeyPress?(row, col, glyph)
        }
    }
}
