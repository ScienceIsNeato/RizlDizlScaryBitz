import Foundation
import CRazerBridge

/// Swift wrapper around the C device transport.
/// All USB operations happen on a dedicated serial queue.
public final class RazerDevice: @unchecked Sendable {
    public static let shared = RazerDevice()

    public enum DeviceError: LocalizedError {
        case notFound
        case usbFailure(String)
        case protocolError

        public var errorDescription: String? {
            switch self {
            case .notFound: return "Keyboard not found"
            case .usbFailure(let reason): return "USB failure: \(reason)"
            case .protocolError: return "Protocol error"
            }
        }
    }

    public enum ConnectionState: Equatable {
        case disconnected
        case connected
        case searching
    }

    private let queue = DispatchQueue(label: "com.rizldizl.usb", qos: .userInteractive)
    public private(set) var state: ConnectionState = .disconnected

    private init() {}

    // MARK: - Connection

    @discardableResult
    public func open() -> Bool {
        queue.sync {
            let rc = bridge_open()
            if rc == 0 {
                state = .connected
                return true
            }
            state = .disconnected
            return false
        }
    }

    public func close() {
        queue.sync {
            bridge_close()
            state = .disconnected
        }
    }

    @discardableResult
    public func reconnect() -> Bool {
        queue.sync {
            let rc = bridge_reconnect()
            if rc == 0 {
                state = .connected
                return true
            }
            state = .disconnected
            return false
        }
    }

    public var lastErrorDescription: String {
        if let cStr = bridge_last_error_str() {
            return String(cString: cStr)
        }
        return String(format: "0x%08x", bridge_last_error())
    }

    // MARK: - Lighting

    @discardableResult
    public func setCustomMode() -> Bool {
        queue.sync { bridge_set_custom_mode() == 0 }
    }

    /// Send a single row of RGB data. buf = [row_id, start_col, stop_col, R,G,B, R,G,B, ...]
    @discardableResult
    public func setCustomFrame(_ buf: [UInt8]) -> Bool {
        queue.sync {
            buf.withUnsafeBufferPointer { ptr in
                bridge_set_custom_frame(ptr.baseAddress, Int32(ptr.count)) == 0
            }
        }
    }

    @discardableResult
    public func setSpectrum() -> Bool {
        queue.sync { bridge_set_spectrum() == 0 }
    }

    @discardableResult
    public func setStatic(r: UInt8, g: UInt8, b: UInt8) -> Bool {
        queue.sync { bridge_set_static(r, g, b) == 0 }
    }
}
