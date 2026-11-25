import AppKit
import SwiftUI

@main
struct CamdeviceApp: App {
    var body: some Scene {
        WindowGroup("Camdevice") {
            HomeView()
                .preferredColorScheme(.dark)
                .tint(Palette.accent)
        }
        .defaultSize(width: 960, height: 650)
        .windowResizability(.contentMinSize)
    }
}

enum Palette {
    static let background = Color(red: 0.037, green: 0.051, blue: 0.075)
    static let panel = Color(red: 0.074, green: 0.094, blue: 0.125)
    static let line = Color(red: 0.16, green: 0.19, blue: 0.23)
    static let muted = Color(red: 0.64, green: 0.69, blue: 0.76)
    static let accent = Color(red: 0.74, green: 0.99, blue: 0.52)
}

private enum Tab { case transfer, photos, preview }

private struct DeviceExportRequest: Identifiable {
    let mode: DeviceExport
    let destination: PhotoFolder?
    var id: DeviceExport { mode }
}

private enum FileOperation {
    case receiving, exporting

    var status: String {
        switch self {
        case .receiving: "正在从设备保存照片…"
        case .exporting: "正在导出照片…"
        }
    }
}

struct HomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("photoFolderBookmark") private var photoFolderBookmark = Data()
    @State private var tab: Tab = .transfer
    @State private var photoFolder: PhotoFolder?
    @State private var folderPhotos: [Photo] = []
    @State private var folderUnavailable = false
    @State private var promptedForFolder = false
    @State private var choosingPhotoFolder = false
    @State private var folderRefreshID = UUID()
    @State private var deviceExport: DeviceExportRequest?
    @State private var preview: Photo?
    @State private var operation: FileOperation?
    @State private var isSelecting = false
    @State private var selectedIDs: Set<URL> = []
    @State private var noticeTitle = "设备导出结果"
    @State private var notice: String?
    @State private var showNotice = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Palette.line).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if tab == .preview { FocusPreviewView() }
                    else if tab == .transfer { transfer }
                    else { photos }
                }
                .frame(maxWidth: 930)
                .padding(32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 720, minHeight: 515)
        .background(Palette.background)
        .task(id: folderRefreshID) { await loadPhotoFolder() }
        .task(id: photoFolder?.url) {
            if let folder = photoFolder { await watchPhotoFolder(folder) }
        }
        .onChange(of: photoFolderBookmark) { _, _ in
            photoFolder = nil
            folderPhotos = []
            folderUnavailable = false
            finishSelecting()
            refreshPhotoFolder()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !photoFolderBookmark.isEmpty { refreshPhotoFolder() }
        }
        .sheet(item: $deviceExport) { request in
            DeviceExportView(mode: request.mode, photoFolderName: request.destination?.url.lastPathComponent) { photos, mirrorJPEG in
                deviceExport = nil
                if let destination = request.destination {
                    await receivePhotos(photos, in: destination, mirrorJPEG: mirrorJPEG)
                }
            }
        }
        .sheet(item: $preview) { PhotoDetail(photo: $0) }
        .alert(noticeTitle, isPresented: $showNotice) {
            Button("好", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "camera")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 36, height: 36)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(Palette.background)
                    .accessibilityHidden(true)
                Text("Camdevice").font(.system(.title2, design: .rounded).weight(.bold))
            }
            .padding(.bottom, 24)
            tabButton("传输", icon: "arrow.down.to.line", destination: .transfer)
            tabButton("USB 实时取景", icon: "viewfinder", destination: .preview)
            tabButton("照片文件夹", icon: "folder", destination: .photos)
            Spacer()
            Text("-NCPA最终兵器-")
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .frame(maxWidth: .infinity, alignment: .center)
            
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 24)
        .frame(width: 194)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.panel)
    }

    private var transfer: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("从设备导出照片")
                    .font(.system(size: 39, weight: .bold)).tracking(-1.9)
                    .accessibilityAddTraits(.isHeader)
                Text("选择连接方式，将相机照片导出到指定文件夹。")
                    .font(.subheadline).foregroundStyle(Palette.muted)
            }
            .padding(.top, 4)

            HStack(spacing: 12) {
                Button { deviceExport = DeviceExportRequest(mode: .bluetooth, destination: photoFolder) } label: {
                    transferCard("蓝牙导出", "查找兼容的蓝牙设备", icon: "wave.3.right", prominent: true)
                }
                Button { deviceExport = DeviceExportRequest(mode: .usb, destination: photoFolder) } label: {
                    transferCard("USB-C 导出", "连接设备并读取照片", icon: "cable.connector", prominent: false)
                }
            }
            .buttonStyle(.plain)
            .disabled(operation != nil || choosingPhotoFolder)

            folderControls

            if let operation { ProgressView(operation.status).font(.subheadline) }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("最近添加").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if !folderPhotos.isEmpty {
                        Button("查看照片") { tab = .photos }
                            .font(.subheadline.weight(.medium))
                    }
                }
                if folderPhotos.isEmpty {
                    Text("照片文件夹中新加入的照片会显示在这里。")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                } else {
                    photoGrid(Array(folderPhotos.prefix(3)), columns: Array(repeating: GridItem(.flexible()), count: 3))
                }
            }
            .padding(.top, 4)
        }
    }

    private func transferCard(_ title: String, _ subtitle: String, icon: String, prominent: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 42, height: 42)
                .background(prominent ? Palette.background.opacity(0.10) : Palette.line,
                            in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline)
                    .foregroundStyle(prominent ? Palette.background.opacity(0.78) : Palette.muted)
            }
            Spacer(minLength: 3)
            Image(systemName: "arrow.up.right").font(.subheadline.weight(.semibold)).accessibilityHidden(true)
        }
        .foregroundStyle(prominent ? Palette.background : .white)
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 85, alignment: .leading)
        .background(prominent ? Palette.accent : Palette.panel, in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18).strokeBorder(prominent ? .clear : Palette.line)
        }
    }

    private var photos: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("照片文件夹").font(.system(size: 39, weight: .bold)).tracking(-1.9)
                .accessibilityAddTraits(.isHeader)
            folderControls
            HStack {
                if photoFolder != nil {
                    Text("\(folderPhotos.count) 张照片")
                        .font(.subheadline).foregroundStyle(Palette.muted)
                }
                Spacer()
                if !folderPhotos.isEmpty { selectionControls }
            }
            if let operation { ProgressView(operation.status).font(.subheadline) }

            if photoFolder != nil && folderPhotos.isEmpty {
                ContentUnavailableView("还没有照片", systemImage: "photo.on.rectangle",
                                       description: Text("从设备导出照片后，可以在这里预览。"))
                    .padding(.vertical, 38)
            } else {
                photoGrid(folderPhotos, allowsSelection: isSelecting)
                    .disabled(operation != nil)
            }
        }
    }

    private var folderControls: some View {
        HStack(spacing: 12) {
            if let folder = photoFolder {
                Label(folder.url.path(percentEncoded: false), systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("更换文件夹…") { choosePhotoFolder() }
                Button("在访达中打开") { NSWorkspace.shared.open(folder.url) }
            } else {
                Text(folderUnavailable ? "照片文件夹暂不可用。请检查磁盘连接或重新选择位置。" : "选择 ESP32 照片的保存位置。")
                    .foregroundStyle(Palette.muted)
                Spacer()
                Button("选择照片文件夹…") { choosePhotoFolder() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .font(.subheadline)
        .disabled(operation != nil || deviceExport != nil || choosingPhotoFolder)
    }

    private var selectionControls: some View {
        HStack {
            if isSelecting {
                Button("全选") { selectedIDs = Set(folderPhotos.map(\.id)) }
                    .disabled(selectedIDs.count == folderPhotos.count)
                Button("完成") { finishSelecting() }
                Button {
                    chooseExportFolder(for: folderPhotos.filter { selectedIDs.contains($0.id) })
                } label: {
                    Label("复制（\(selectedIDs.count)）", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedIDs.isEmpty)
            } else {
                Button("选择照片") { isSelecting = true }
            }
        }
        .disabled(operation != nil)
    }

    private func photoGrid(
        _ photos: [Photo],
        allowsSelection: Bool = false,
        columns: [GridItem] = [GridItem(.adaptive(minimum: 145), spacing: 12)]
    ) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(photos) { photo in
                let selected = allowsSelection && selectedIDs.contains(photo.id)
                Button {
                    if allowsSelection {
                        if selected { selectedIDs.remove(photo.id) }
                        else { selectedIDs.insert(photo.id) }
                    } else {
                        preview = photo
                    }
                } label: {
                    PhotoTile(photo: photo)
                        .overlay(alignment: .topTrailing) {
                            if allowsSelection {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(selected ? Palette.accent : .white)
                                    .padding(6)
                                    .background(.black.opacity(0.64), in: Circle())
                                    .padding(7)
                                    .accessibilityHidden(true)
                            }
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(selected ? Palette.accent : .clear, lineWidth: 2)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(photo.name)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .contextMenu {
                    Button("复制到文件夹…") { chooseExportFolder(for: [photo]) }
                        .disabled(operation != nil)
                }
            }
        }
    }

    private func tabButton(_ label: String, icon: String, destination: Tab) -> some View {
        Button {
            if destination != .photos { finishSelecting() }
            tab = destination
            if !photoFolderBookmark.isEmpty { refreshPhotoFolder() }
        } label: {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tab == destination ? Palette.accent : Palette.muted)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(tab == destination ? Palette.accent.opacity(0.075) : .clear,
                            in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tab == destination ? .isSelected : [])
    }

    private func choosePhotoFolder() {
        guard !choosingPhotoFolder else { return }
        promptedForFolder = true
        choosingPhotoFolder = true
        let panel = NSOpenPanel()
        panel.title = "选择照片文件夹"
        panel.message = "从 ESP32 导出的照片会直接保存到这里。旧版内置相册的照片也会在首次迁移时复制到这里。"
        panel.prompt = "使用此文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = photoFolder?.url ?? FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
        panel.begin { response in
            choosingPhotoFolder = false
            if response == .OK, let url = panel.url { savePhotoFolder(url) }
        }
    }

    private func savePhotoFolder(_ url: URL) {
        do {
            let folder = PhotoFolder(url: url)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.isWritableFile(atPath: url.path(percentEncoded: false)) else {
                report("这个文件夹不可写。请选择其他位置。", title: "无法使用该文件夹")
                return
            }
            photoFolderBookmark = try folder.bookmark()
            refreshPhotoFolder()
        } catch {
            report("无法记住这个文件夹。请重新选择位置。", title: "无法使用该文件夹")
        }
    }

    private func refreshPhotoFolder() {
        folderRefreshID = UUID()
    }

    private func loadPhotoFolder() async {
        let bookmark = photoFolderBookmark
        if bookmark.isEmpty {
            if !promptedForFolder { choosePhotoFolder() }
            return
        }
        let result = await Task.detached(priority: .userInitiated) {
            Result {
                let folder = try PhotoFolder(bookmark: bookmark)
                return (folder, try folder.photos())
            }
        }.value
        guard !Task.isCancelled, bookmark == photoFolderBookmark else { return }
        switch result {
        case let .success((folder, photos)):
            photoFolder = folder
            folderPhotos = photos
            folderUnavailable = false
            selectedIDs.formIntersection(photos.map(\.id))
        case .failure:
            photoFolder = nil
            folderPhotos = []
            folderUnavailable = true
            finishSelecting()
        }
    }

    private func receivePhotos(_ urls: [URL], in destination: PhotoFolder, mirrorJPEG: Bool) async {
        guard !urls.isEmpty, operation == nil else { return }
        operation = .receiving
        let result = await Task.detached(priority: .userInitiated) {
            destination.save(urls, validatingImages: true, mirroringJPEG: mirrorJPEG)
        }.value
        refreshPhotoFolder()
        operation = nil
        if result.saved > 0 { tab = .photos }
        if result.failed > 0 {
            report("已保存 \(result.saved) 张，另有 \(result.failed) 张未能处理或保存。")
        }
    }

    private func watchPhotoFolder(_ folder: PhotoFolder) async {
        let changes = folder.changes()
        let migration = await Task.detached(priority: .utility) {
            Result { try folder.migrateLegacyPhotos() }
        }.value
        guard !Task.isCancelled else { return }

        switch migration {
        case let .success(result):
            if let result {
                if result.saved > 0 { refreshPhotoFolder() }
                if result.failed > 0 {
                    report("有 \(result.failed) 张旧照片未能复制。原照片仍在旧相册中。", title: "旧照片迁移未完成")
                }
            }
        case .failure:
            report("暂时无法读取旧相册。", title: "旧照片迁移未完成")
        }

        for await _ in changes {
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return
            }
            refreshPhotoFolder()
        }
    }

    private func finishSelecting() {
        isSelecting = false
        selectedIDs.removeAll()
    }

    private func chooseExportFolder(for photos: [Photo]) {
        guard !photos.isEmpty, operation == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "选择照片复制位置"
        panel.prompt = "复制到这里"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        let files = photos.map(\.url)
        operation = .exporting
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                PhotoFolder(url: directory).save(files)
            }.value
            refreshPhotoFolder()
            operation = nil
            if result.failed == 0 {
                finishSelecting()
                report("已将 \(result.saved) 张照片导出到「\(directory.lastPathComponent)」。", title: "导出完成")
            } else {
                report("已导出 \(result.saved) 张，另有 \(result.failed) 张未能导出。", title: "导出结果")
            }
        }
    }

    private func report(_ message: String, title: String = "设备导出结果") {
        noticeTitle = title
        notice = message
        showNotice = true
    }
}

struct PhotoTile: View {
    let photo: Photo

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { size in
                    if let image = photo.image() {
                        Image(nsImage: image)
                            .resizable().scaledToFill()
                            .frame(width: size.size.width, height: size.size.height)
                    } else {
                        Image(systemName: "photo")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .foregroundStyle(Palette.muted)
                    }
                }
            }
            .background(Palette.panel)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }
}

private struct PhotoDetail: View {
    let photo: Photo
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(photo.name).font(.headline).lineLimit(1)
                Text(photo.size).font(.caption.monospacedDigit()).foregroundStyle(Palette.muted)
                Spacer()
                ShareLink(item: photo.url) {
                    Label("分享照片", systemImage: "square.and.arrow.up")
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let image = photo.image(maxSize: 1800) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(photo.name)
            }
        }
        .padding(20)
        .frame(width: 620, height: 500)
        .background(Palette.background)
    }
}

private struct FocusPreviewView: View {
    @State private var ports = SerialCamera.ports()
    @State private var port = SerialCamera.ports().first ?? ""
    @State private var running = false
    @State private var frame: NSImage?
    @State private var enlarged = false
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("USB 实时取景").font(.largeTitle.bold())
            Text("转动镜头调焦，可放大画面中央检查细节。").foregroundStyle(Palette.muted)
            HStack {
                if ports.isEmpty {
                    Text("等待 USB 相机").foregroundStyle(Palette.muted)
                } else {
                    Picker("串口", selection: $port) {
                        ForEach(ports, id: \.self) { Text($0).tag($0) }
                    }.disabled(running)
                }
                Button(running ? "停止取景" : "开始取景") {
                    frame = nil
                    message = ""
                    running.toggle()
                }.disabled(port.isEmpty && !running)
                Toggle("中心放大 2×", isOn: $enlarged).toggleStyle(.button)
            }
            ZStack {
                Color.black
                if let frame {
                    Image(nsImage: frame).resizable().scaledToFit().scaleEffect(enlarged ? 2 : 1)
                } else if running {
                    ProgressView("正在获取画面…")
                }
            }.aspectRatio(4/3, contentMode: .fit).clipped()
            if !message.isEmpty { Text(message).foregroundStyle(Palette.muted) }
        }
        .task {
            while !Task.isCancelled {
                let available = SerialCamera.ports()
                ports = available
                if !running && !available.contains(port) { port = available.first ?? "" }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .task(id: running) {
            guard running else { return }
            do {
                try await SerialCamera(port: port).withPreviewFrames { frames in
                    for try await jpeg in frames {
                        guard !Task.isCancelled else { return }
                        guard let image = NSImage(data: jpeg) else { throw CocoaError(.fileReadCorruptFile) }
                        frame = image
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                frame = nil
                message = error.localizedDescription
                running = false
            }
        }
    }
}
