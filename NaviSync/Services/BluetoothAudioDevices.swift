#if os(macOS)
import IOBluetooth
import Observation

/// Paired Bluetooth audio devices on the Mac, with connect / disconnect.
/// (iOS has no public API for this; there the system output picker is all an app can offer.)
@MainActor
@Observable
final class BluetoothAudioDevices {
    struct Device: Identifiable {
        let id: String
        let name: String
        let isConnected: Bool
        let device: IOBluetoothDevice
    }

    private(set) var devices: [Device] = []
    /// Device currently being connected or disconnected.
    private(set) var busyID: String?
    private(set) var lastError: String?

    @ObservationIgnored private var delegate: ConnectionDelegate?

    func refresh() {
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let audioClass = BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorAudio)
        devices = paired
            .filter { $0.deviceClassMajor == audioClass }
            .map { device in
                Device(
                    id: device.addressString ?? device.nameOrAddress ?? UUID().uuidString,
                    name: device.nameOrAddress ?? "Unknown device",
                    isConnected: device.isConnected(),
                    device: device
                )
            }
            .sorted { ($0.isConnected ? 0 : 1, $0.name) < ($1.isConnected ? 0 : 1, $1.name) }
    }

    func toggle(_ entry: Device) {
        guard busyID == nil else { return }
        lastError = nil
        if entry.isConnected {
            entry.device.closeConnection()
            refresh()
            return
        }
        busyID = entry.id
        // Asynchronous: IOBluetooth calls connectionComplete(_:status:) on the main run loop.
        let delegate = ConnectionDelegate { [weak self] status in
            guard let self else { return }
            self.busyID = nil
            self.delegate = nil
            if status != 0 {
                self.lastError = "Couldn't connect to \(entry.name). Is it switched on and in range?"
            }
            self.refresh()
        }
        self.delegate = delegate
        if entry.device.openConnection(delegate) != 0 {
            busyID = nil
            self.delegate = nil
            lastError = "Couldn't connect to \(entry.name)."
        }
    }
}

private final class ConnectionDelegate: NSObject {
    let completion: @MainActor (IOReturn) -> Void

    init(completion: @escaping @MainActor (IOReturn) -> Void) {
        self.completion = completion
    }

    @objc func connectionComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        MainActor.assumeIsolated { completion(status) }
    }
}
#endif
