import Foundation
import IOKit
import IOKit.usb
import CRazerBridge

public struct RazerDeviceEntry: Identifiable, Equatable {
    public let id: UInt16  // product ID
    public let name: String

    public init(id: UInt16, name: String) {
        self.id = id
        self.name = name
    }
}

/// Watches for Razer USB device connect/disconnect events via IOKit notifications.
public final class USBWatcher: ObservableObject {
    @Published public var devices: [RazerDeviceEntry] = []

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0

    public init() {
        refresh()
        startWatching()
    }

    deinit {
        stopWatching()
    }

    public func refresh() {
        var infos = [BridgeDeviceInfo](repeating: BridgeDeviceInfo(), count: 32)
        let count = infos.withUnsafeMutableBufferPointer { ptr in
            Int(bridge_list_devices(ptr.baseAddress, Int32(ptr.count)))
        }
        let newDevices = (0..<count).map { i in
            let info = infos[i]
            let name = withUnsafePointer(to: info.name) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 64) {
                    String(cString: $0)
                }
            }
            return RazerDeviceEntry(id: info.product_id, name: name)
        }
        DispatchQueue.main.async {
            self.devices = newDevices
        }
    }

    // MARK: - IOKit USB notifications

    private func startWatching() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        // Use IOUSBHostDevice — the legacy kIOUSBDeviceClassName vendor filter
        // is broken on macOS 15+. We watch all USB devices and filter in refresh().
        let matchingDict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Watch for additions
        let addDict = matchingDict.mutableCopy() as! NSMutableDictionary
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            addDict,
            { refcon, iterator in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
                // Drain the iterator
                while case let device = IOIteratorNext(iterator), device != 0 {
                    IOObjectRelease(device)
                }
                // Refresh after a short delay to let the device enumerate
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    watcher.refresh()
                }
            },
            selfPtr,
            &addedIterator
        )
        // Drain initial iterator
        while case let device = IOIteratorNext(addedIterator), device != 0 {
            IOObjectRelease(device)
        }

        // Watch for removals
        let removeDict = matchingDict.mutableCopy() as! NSMutableDictionary
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            removeDict,
            { refcon, iterator in
                guard let refcon = refcon else { return }
                let watcher = Unmanaged<USBWatcher>.fromOpaque(refcon).takeUnretainedValue()
                while case let device = IOIteratorNext(iterator), device != 0 {
                    IOObjectRelease(device)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    watcher.refresh()
                }
            },
            selfPtr,
            &removedIterator
        )
        while case let device = IOIteratorNext(removedIterator), device != 0 {
            IOObjectRelease(device)
        }
    }

    private func stopWatching() {
        if addedIterator != 0 { IOObjectRelease(addedIterator) }
        if removedIterator != 0 { IOObjectRelease(removedIterator) }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
        }
    }
}
