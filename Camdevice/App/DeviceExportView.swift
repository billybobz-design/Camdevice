import AppKit
import SwiftUI

enum DeviceExport: String, Identifiable {
    case bluetooth, usb

    var id: Self { self }
    var title: String { self == .bluetooth ? "蓝牙导出" : "USB-C 导出" }
    var icon: String { self == .bluetooth ? "wave.3.right" : "cable.connector" }
}

struct DeviceExportView: View {
    let mode: DeviceExport
    let photoFolderName: String?
    let onPhotos: ([URL], Bool) async -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mirrorJPEGOnExport") private var mirrorJPEGOnExport = true
    @StateObject private var bluetooth = BluetoothDiscovery()
    @State private var usbDevices: [USBDevice] = []
    @State private var serialCameras: [SerialCamera] = []
    @State private var checkingUSB = true
    @State private var readingPhotos = false
    @State private var takingPhoto = false
    @State private var clearingFlash = false
    @State private var showCleanupConfirmation = false
    @State private var cameraToClean: SerialCamera?
    @State private var serialIssue: String?
    @State private var cameraMessage: String?
    @State private var resultMessage: String?
    @State private var showResult = false
    @State private var refreshID = UUID()

    private var workspace: NotificationCenter { NSWorkspace.shared.notificationCenter }
    private var busy: Bool { readingPhotos || takingPhoto || clearingFlash }
    private var canExport: Bool { !busy && !checkingUSB && photoFolderName != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(mode.title, systemImage: mode.icon).font(.title2.bold())
                Spacer()
                if mode == .bluetooth {
                    Button("重新扫描") { bluetooth.start() }
                } else {
                    Button("重新检测") { refreshID = UUID() }.disabled(busy || checkingUSB)
                }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                    .disabled(busy)
            }
            Divider()
            if mode == .bluetooth { bluetoothList } else { usbList }
        }
        .padding(22)
        .frame(width: 570)
        .background(Palette.background)
        .interactiveDismissDisabled(busy)
        .onAppear {
            if mode == .bluetooth { bluetooth.start() }
        }
        .onDisappear { bluetooth.stop() }
        .task(id: refreshID) {
            if mode == .usb { await refreshUSB() }
        }
        .onReceive(workspace.publisher(for: NSWorkspace.didMountNotification)) { _ in
            if mode == .usb { refreshID = UUID() }
        }
        .onReceive(workspace.publisher(for: NSWorkspace.didUnmountNotification)) { notification in
            if mode == .usb {
                if let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL {
                    usbDevices.removeAll { $0.volume == volume }
                }
                refreshID = UUID()
            }
        }
        .alert("USB-C 导出", isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
        .confirmationDialog("清理闪存照片？", isPresented: $showCleanupConfirmation, titleVisibility: .visible,
                            presenting: cameraToClean) { camera in
            Button("删除全部闪存照片", role: .destructive) { clearFlash(using: camera) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("将永久删除相机板载闪存中的所有 Camdevice 照片。Mac 上已导出的照片和 microSD 卡中的照片会保留。")
        }
    }

    @ViewBuilder
    private var bluetoothList: some View {
        if bluetooth.devices.isEmpty {
            ContentUnavailableView("等待蓝牙设备", systemImage: mode.icon, description: Text(bluetooth.status))
                .frame(maxWidth: .infinity, minHeight: 185)
        } else {
            deviceList {
                ForEach(bluetooth.devices) { device in
                    deviceRow(name: device.name, uuid: device.id, uuidLabel: "蓝牙设备 UUID")
                }
            }
            Text("已发现兼容设备。蓝牙照片传输待固件适配。")
                .font(.footnote).foregroundStyle(Palette.muted)
        }
    }

    @ViewBuilder
    private var usbList: some View {
        if usbDevices.isEmpty && serialCameras.isEmpty {
            ContentUnavailableView("等待 USB-C 设备", systemImage: mode.icon,
                                   description: Text(checkingUSB ? "正在检测设备…" :
                                        serialIssue ?? "请用支持数据传输的 USB-C 线连接相机。"))
                .frame(maxWidth: .infinity, minHeight: 185)
        } else {
            deviceList {
                ForEach(serialCameras) { camera in
                    HStack(spacing: 12) {
                        deviceRow(name: "Camdevice 相机", detail: camera.supportsFlashCleanup
                                  ? camera.port : camera.port + " · 更新固件后可清理")
                        Spacer()
                        Button("清理闪存照片", role: .destructive) {
                            cameraToClean = camera
                            showCleanupConfirmation = true
                        }
                        .disabled(busy || checkingUSB || !camera.supportsFlashCleanup)
                        Button("拍照") { capture(using: camera) }
                            .disabled(busy || checkingUSB)
                        Button("导出照片") { readPhotos(from: camera) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canExport)
                    }
                }
                ForEach(usbDevices) { device in
                    HStack(spacing: 12) {
                        deviceRow(name: device.name, uuid: device.uuid, uuidLabel: "设备 UUID")
                        Spacer()
                        Button("导出照片") { readPhotos(from: device) }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canExport)
                    }
                }
            }
            Text(photoFolderName.map { "保存到「\($0)」" } ?? "请在传输页选择照片文件夹后再导出。")
                .font(.footnote)
                .foregroundStyle(Palette.muted)
            Toggle("导出时左右镜像 JPEG 照片", isOn: $mirrorJPEGOnExport)
                .disabled(busy)
        }
        if readingPhotos { ProgressView("正在读取设备照片…").font(.subheadline) }
        if takingPhoto { ProgressView("正在拍照…").font(.subheadline) }
        if clearingFlash { ProgressView("正在清理闪存照片…").font(.subheadline) }
        if let cameraMessage { Text(cameraMessage).font(.subheadline).foregroundStyle(Palette.muted) }
    }

    private func deviceList<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8, content: rows)
        }
        .frame(height: 185)
    }

    private func deviceRow(name: String, uuid: UUID, uuidLabel: String) -> some View {
        deviceRow(name: name, detail: uuidLabel + " · " + uuid.uuidString)
    }

    private func deviceRow(name: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).font(.headline).lineLimit(1)
            Text(detail)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .textSelection(.enabled)
        }
        .padding(.vertical, 9)
    }

    private func refreshUSB() async {
        checkingUSB = true
        let devices = await Task.detached(priority: .userInitiated) { USBDiscovery.devices() }.value
        guard !Task.isCancelled else { return }
        usbDevices = devices
        var previousPorts: [String]?
        while !Task.isCancelled {
            let ports = SerialCamera.ports()
            if !busy && previousPorts != ports {
                previousPorts = ports
                checkingUSB = true
                serialCameras.removeAll { !ports.contains($0.port) }
                let scan = await Task.detached(priority: .userInitiated) {
                    var cameras: [SerialCamera] = []
                    var issue: String?
                    for port in ports {
                        let camera = SerialCamera(port: port)
                        do {
                            cameras.append(try camera.identify())
                        } catch {
                            if issue == nil { issue = error.localizedDescription }
                        }
                    }
                    return (cameras, issue)
                }.value
                guard !Task.isCancelled else { return }
                serialCameras = scan.0
                serialIssue = scan.1
                checkingUSB = false
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func readPhotos(from device: USBDevice) {
        readPhotos {
            do {
                return try USBDiscovery.photos(on: device)
            } catch {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [
                    NSLocalizedDescriptionKey: "无法读取设备。请确认数据线已连接，再试一次。"
                ])
            }
        }
    }

    private func readPhotos(from camera: SerialCamera) {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Camdevice-" + UUID().uuidString, directoryHint: .isDirectory)
        readPhotos(temporaryFolder: folder) { try camera.downloadPhotos(to: folder) }
    }

    private func readPhotos(temporaryFolder: URL? = nil, load: @escaping @Sendable () throws -> [URL]) {
        let mirrorJPEG = mirrorJPEGOnExport
        readingPhotos = true
        cameraMessage = nil
        Task {
            defer {
                if let temporaryFolder { try? FileManager.default.removeItem(at: temporaryFolder) }
                readingPhotos = false
            }
            do {
                let photos = try await Task.detached(priority: .userInitiated, operation: load).value
                guard !photos.isEmpty else {
                    report("设备的 DCIM 文件夹里没有可导出的照片。")
                    return
                }
                await onPhotos(photos, mirrorJPEG)
            } catch {
                report(error.localizedDescription)
                refreshID = UUID()
            }
        }
    }

    private func capture(using camera: SerialCamera) {
        takingPhoto = true
        cameraMessage = nil
        Task {
            defer { takingPhoto = false }
            do {
                try await Task.detached(priority: .userInitiated) { try camera.takePhoto() }.value
                cameraMessage = "拍照成功，照片已保存在设备上。"
            } catch {
                report(error.localizedDescription)
                refreshID = UUID()
            }
        }
    }

    private func clearFlash(using camera: SerialCamera) {
        clearingFlash = true
        cameraMessage = nil
        Task {
            defer { clearingFlash = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try camera.clearFlashPhotos()
                }.value
                if result.failed > 0 {
                    report("已删除 \(result.removed) 张闪存照片，另有 \(result.failed) 张未能删除。")
                } else if result.removed == 0 {
                    cameraMessage = "闪存里没有可清理的照片。"
                } else {
                    cameraMessage = "已删除 \(result.removed) 张闪存照片。"
                }
            } catch {
                report(error.localizedDescription)
                refreshID = UUID()
            }
        }
    }

    private func report(_ message: String) {
        resultMessage = message
        showResult = true
    }
}
