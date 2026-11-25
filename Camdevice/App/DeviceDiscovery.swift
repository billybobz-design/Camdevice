import Combine
import CoreBluetooth
import DiskArbitration
import Foundation

enum DeviceProtocol {
    static let serviceID = UUID(uuidString: "C405D5C7-16FA-48EA-86C7-497F5BE293F0")!
}

struct BluetoothDevice: Identifiable {
    let id: UUID
    let name: String
}

final class BluetoothDiscovery: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var devices: [BluetoothDevice] = []
    @Published private(set) var status = "正在准备蓝牙…"

    private var central: CBCentralManager?
    private var active = false

    func start() {
        active = true
        if let central {
            central.stopScan()
            centralManagerDidUpdateState(central)
        } else {
            central = CBCentralManager(delegate: self, queue: .main,
                                       options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
    }

    func stop() {
        active = false
        central?.stopScan()
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard active else { return }
        devices = []
        switch central.state {
        case .poweredOn:
            status = "正在扫描兼容设备…"
            central.scanForPeripherals(withServices: [CBUUID(nsuuid: DeviceProtocol.serviceID)], options: nil)
        case .poweredOff: status = "请打开 Mac 的蓝牙。"
        case .unauthorized: status = "请在系统设置的「隐私与安全性」中允许 Camdevice 使用蓝牙。"
        case .unsupported: status = "这台 Mac 无法使用低功耗蓝牙。"
        case .unknown, .resetting: status = "正在准备蓝牙…"
        @unknown default: status = "蓝牙暂不可用。"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard active, central.isScanning else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let device = BluetoothDevice(id: peripheral.identifier, name: name.isEmpty ? "Camdevice 设备" : name)
        devices.removeAll { $0.id == device.id }
        devices.append(device)
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct USBDevice: Identifiable, Sendable {
    let volume: URL
    let uuid: UUID
    let name: String

    var id: URL { volume }
}

enum USBDiscovery {
    private struct Manifest: Decodable {
        let serviceUUID: UUID
        let uuid: UUID
        let name: String
    }

    static func devices() -> [USBDevice] {
        guard let session = DASessionCreate(kCFAllocatorDefault) else { return [] }
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsInternalKey]
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                            options: [.skipHiddenVolumes]) ?? []
        return volumes.compactMap { volume -> USBDevice? in
            guard let traits = try? volume.resourceValues(forKeys: Set(keys)),
                  traits.volumeIsLocal == true, traits.volumeIsInternal == false,
                  let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
                  let description = DADiskCopyDescription(disk) as? [String: Any],
                  let transport = description[kDADiskDescriptionDeviceProtocolKey as String] as? String,
                  transport.caseInsensitiveCompare("USB") == .orderedSame else { return nil }
            return identifiedVolume(volume)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // Read the device identity only from the root of a qualifying USB volume.
    static func identifiedVolume(_ volume: URL) -> USBDevice? {
        let manifestURL = volume.appending(path: "CAMDEVICE.JSON", directoryHint: .notDirectory)
        guard let resources = try? manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              resources.isRegularFile == true, resources.isSymbolicLink == false,
              let file = try? FileHandle(forReadingFrom: manifestURL) else { return nil }
        defer { try? file.close() }

        guard let data = try? file.read(upToCount: 2049), data.count <= 2048,
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.serviceUUID == DeviceProtocol.serviceID else { return nil }
        let name = manifest.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64, name.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        return USBDevice(volume: volume, uuid: manifest.uuid, name: name)
    }

    static func photos(on device: USBDevice) throws -> [URL] {
        guard devices().contains(where: { $0.volume == device.volume && $0.uuid == device.uuid }) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        return photoURLs(in: device.volume)
    }

    static func photoURLs(in volume: URL) -> [URL] {
        let directory = volume.appending(path: "DCIM", directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let traits = try? directory.resourceValues(forKeys: Set(keys)),
              traits.isDirectory == true, traits.isSymbolicLink == false,
              let entries = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys,
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var urls: [URL] = []
        for case let url as URL in entries {
            guard let info = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if info.isSymbolicLink == true {
                entries.skipDescendants()
            } else if info.isRegularFile == true, Photo.supports(url) {
                urls.append(url)
            }
        }
        return urls.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}
