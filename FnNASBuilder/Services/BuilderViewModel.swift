import AppKit
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BuilderViewModel: ObservableObject {
    @Published var inputFile: URL?
    @Published var imageURLText = ""
    @Published var deviceSearchText = ""
    @Published var selectedBoard = "s922x-ct2000"
    @Published var autoKernel = true
    @Published var downloadMirror: DownloadMirror = .official {
        didSet { UserDefaults.standard.set(downloadMirror.rawValue, forKey: Self.downloadMirrorPreferenceKey) }
    }
    @Published var skipKernel = false
    @Published var builderName = ""
    @Published var kernel = "6.18.y"
    @Published var rootfsExpand = "16"
    @Published var imageSize = "512/6144"
    @Published var outputDirectory: URL
    @Published var phase: BuildPhase = .idle
    @Published var progress = 0.0
    @Published var logs = ""
    @Published var outputs: [BuildArtifact] = []
    @Published var environment = EnvironmentStatus()
    @Published var isRunning = false
    @Published var isCleaningEnvironment = false
    @Published var alertMessage: String?

    private static let downloadMirrorPreferenceKey = "FnNASBuilder.downloadMirror"

    private let container = ContainerService()
    private let buildService = BuildService()
    private var task: Task<Void, Never>?
    private var elapsedTimerTask: Task<Void, Never>?
    private var cancellationRequested = false
    @Published private(set) var currentLogFile: URL?
    @Published private(set) var buildStartedAt: Date?
    @Published private(set) var buildFinishedAt: Date?
    @Published private(set) var elapsedBuildTime: TimeInterval = 0

    var selectedDevice: Device? { devices.first(where: { $0.id == selectedBoard }) }

    var filteredDevices: [Device] {
        let query = deviceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return devices }
        var matches = devices.filter { device in
            [device.id, device.model, device.soc, device.platform, device.description]
                .contains { $0.localizedCaseInsensitiveContains(query) }
        }
        // Keep the current selection visible while filtering so Picker never loses its tag.
        if let selectedDevice, !matches.contains(selectedDevice) { matches.insert(selectedDevice, at: 0) }
        return matches
    }

    var environmentIsReady: Bool {
        environment.containerAvailable && environment.appleSilicon && environment.systemOK
    }

    var hasLowDiskSpace: Bool { environment.freeSpace > 0 && environment.freeSpace < 20 * 1024 * 1024 * 1024 }

    var formattedFreeSpace: String {
        ByteCountFormatter.string(fromByteCount: environment.freeSpace, countStyle: .file)
    }

    var inputValidationMessage: String? {
        if let inputFile {
            guard FileManager.default.fileExists(atPath: inputFile.path) else { return "所选基础镜像已不存在，请重新选择文件。" }
            guard ["img", "gz"].contains(inputFile.pathExtension.lowercased()) else { return "基础镜像必须是 .img 或 .img.gz 文件。" }
            return nil
        }
        let value = imageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if isRemoteImageURL(value) || FileManager.default.fileExists(atPath: value) { return nil }
        return "请输入有效的 http(s) 地址，或选择存在的 .img / .img.gz 文件。"
    }

    var canStartBuild: Bool {
        guard !isRunning, !isCleaningEnvironment, environmentIsReady, selectedDevice != nil else { return false }
        let value = imageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasURL = isRemoteImageURL(value)
        let localFileValid = inputFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        return localFileValid || hasURL || FileManager.default.fileExists(atPath: value)
    }

    var progressLabel: String {
        if phase == .failed { return "失败" }
        if phase == .cancelled { return "已取消" }
        if phase == .finished { return "100%" }
        if isRunning && progress <= 0 { return "处理中" }
        return "\(Int(progress * 100))%"
    }

    /// 供界面稳定读取的构建耗时文字。构建期间每秒刷新，构建结束后固定为本次总耗时。
    var buildElapsedText: String {
        // Explicitly read this published value so SwiftUI invalidates the computed text once
        // per second while a build is running.
        let duration = elapsedBuildTime
        guard buildStartedAt != nil else { return "" }
        if isRunning {
            return "已用 \(formattedBuildDuration(duration))"
        }
        if buildFinishedAt != nil {
            return "构建总时长 \(formattedBuildDuration(duration))"
        }
        return ""
    }

    /// “—” 表示尚未发起过构建，便于 SwiftUI 决定是否显示该标签。
    var buildDurationText: String {
        let text = buildElapsedText
        return text.isEmpty ? "—" : text
    }

    var startButtonHint: String {
        if environment.systemOK == false { return "需要 macOS 26 或更高版本。" }
        if !environment.appleSilicon { return "此应用仅支持 Apple Silicon Mac。" }
        if !environment.containerAvailable { return "请先安装 Apple Container，然后点击“重新检测”。" }
        if selectedDevice == nil { return "请选择目标设备。" }
        if !canStartBuild { return "请选择基础镜像，或输入有效的 HTTP/HTTPS 下载地址。" }
        return ""
    }

    init() {
        outputDirectory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].appendingPathComponent("FnNASBuilder", isDirectory: true)
        if let rawValue = UserDefaults.standard.string(forKey: Self.downloadMirrorPreferenceKey),
           let savedMirror = DownloadMirror(rawValue: rawValue) {
            downloadMirror = savedMirror
        }
        Task { await refreshEnvironment() }
    }

    var devices: [Device] { DeviceDatabase.shared.devices }

    func refreshEnvironment() async { environment = await container.checkEnvironment() }

    /// Opens the Apple-signed installer that is bundled with the app. Installation happens in
    /// macOS Installer and requires the user's administrator authorization.
    func installAppleContainer() {
        guard let installer = container.bundledInstallerURL() else {
            alertMessage = "未找到内置的 Apple Container 安装包。请重新下载完整的 FnNAS Builder App。"
            return
        }
        guard NSWorkspace.shared.open(installer) else {
            alertMessage = "无法打开 Apple Container 安装包。请在 Finder 中重新打开 App 后重试。"
            return
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "img") ?? .data, UTType(filenameExtension: "gz") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            inputFile = url
            // 将用户通过文件选择器选中的绝对路径回填到输入框，便于确认和再次编辑。
            imageURLText = url.path
        }
    }

    func acceptTypedImagePath() {
        let value = imageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, FileManager.default.fileExists(atPath: value) else { return }
        let url = URL(fileURLWithPath: value)
        guard ["img", "gz"].contains(url.pathExtension.lowercased()) else { return }
        inputFile = url
        // 手动输入本地路径被识别后同样保留路径，避免输入框看起来像没有选择文件。
        imageURLText = url.path
    }

    func clearImageSelection() {
        inputFile = nil
        imageURLText = ""
    }

    func revealLogsDirectory() {
        guard let logsURL = environment.logsURL else { return }
        NSWorkspace.shared.open(logsURL)
    }

    func revealCurrentLog() {
        guard let currentLogFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([currentLogFile])
    }

    func copyLogs() {
        guard !logs.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logs, forType: .string)
    }

    func clearVisibleLogs() {
        logs = ""
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { outputDirectory = url }
    }

    /// 清理本 App 创建的持久容器和工作目录。构建日志、用户选择的源镜像和输出目录均保留。
    func clearBuildEnvironment() {
        guard !isRunning, !isCleaningEnvironment else { return }
        isCleaningEnvironment = true

        Task {
            defer { isCleaningEnvironment = false }

            do {
                try await container.clearBuildEnvironment { _ in }
                await refreshEnvironment()
                alertMessage = "构建环境已清理。下次开始构建时会重新创建容器并安装所需依赖。"
            } catch {
                alertMessage = "清理构建环境失败：\(error.localizedDescription)"
            }
        }
    }

    func startBuild() {
        guard !isRunning, !isCleaningEnvironment else { return }
        guard environmentIsReady else {
            alertMessage = environment.message + "请先完成环境准备后再开始构建。"
            return
        }
        guard let device = devices.first(where: { $0.id == selectedBoard }) else {
            alertMessage = "没有找到所选设备。请确认 model_database.conf 已包含可构建设备。"
            return
        }
        acceptTypedImagePath()
        let enteredValue = imageURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        let inputURL: URL? = isRemoteImageURL(enteredValue) ? URL(string: enteredValue) : nil
        guard inputFile != nil || inputURL != nil else {
            alertMessage = "请选择 .img/.img.gz 基础镜像，或输入有效的 HTTPS 下载 URL。"
            return
        }
        let options = BuildOptions(autoKernel: autoKernel, downloadMirror: downloadMirror, skipKernel: skipKernel, kernel: kernel.nilIfEmpty, rootfsExpand: rootfsExpand, imageSize: imageSize, builderName: builderName)
        let request = BuildRequest(imageURL: inputURL, imageFile: inputFile, device: device, options: options, outputDirectory: outputDirectory)
        cancellationRequested = false
        beginBuildTiming()
        isRunning = true
        task = Task { await run(request) }
    }

    func cancelBuild() {
        guard isRunning || task != nil else { return }
        cancellationRequested = true
        task?.cancel()
        buildService.cancel()
        phase = .cancelled
        appendLog("用户请求取消构建。")
    }

    func reveal(_ artifact: BuildArtifact) { NSWorkspace.shared.activateFileViewerSelecting([artifact.url]) }

    private func run(_ request: BuildRequest) async {
        // `startBuild()` marks the task as running before scheduling it, so an immediate
        // user cancellation cannot be overwritten by this task's initial UI state.
        guard !Task.isCancelled, !cancellationRequested else {
            phase = .cancelled
            isRunning = false
            finishBuildTiming()
            task = nil
            return
        }

        logs = ""
        outputs = []
        progress = 0
        phase = .preparing
        prepareLogFile()
        defer {
            isRunning = false
            finishBuildTiming()
            task = nil
        }

        do {
            let artifacts = try await buildService.build(
                request,
                progress: { [weak self] update in
                    Task { @MainActor in
                        guard let self, !self.cancellationRequested else { return }
                        self.phase = update.phase
                        self.progress = update.fraction ?? self.progress
                    }
                },
                log: { [weak self] text in
                    Task { @MainActor in
                        self?.appendLog(text)
                    }
                }
            )

            guard !Task.isCancelled, !cancellationRequested else {
                phase = .cancelled
                return
            }

            outputs = artifacts
            phase = .finished
            progress = 1
            appendLog("构建成功，已生成 \(artifacts.count) 个 .img.gz 文件。")
        } catch is CancellationError {
            phase = .cancelled
        } catch {
            // A terminated command may report a normal non-zero exit status instead of
            // CancellationError. The user's explicit cancellation always wins semantically.
            if Task.isCancelled || cancellationRequested {
                phase = .cancelled
            } else {
                phase = .failed
                alertMessage = error.localizedDescription
                appendLog("错误：\(error.localizedDescription)")
            }
        }
    }

    private func beginBuildTiming() {
        elapsedTimerTask?.cancel()
        buildStartedAt = Date()
        buildFinishedAt = nil
        elapsedBuildTime = 0

        elapsedTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                guard !Task.isCancelled, let self else { break }
                self.refreshElapsedBuildTime()
            }
        }
    }

    private func refreshElapsedBuildTime() {
        guard let buildStartedAt else { return }
        elapsedBuildTime = max(0, Date().timeIntervalSince(buildStartedAt))
    }

    private func finishBuildTiming() {
        elapsedTimerTask?.cancel()
        elapsedTimerTask = nil
        guard let buildStartedAt else { return }
        let finishedAt = Date()
        buildFinishedAt = finishedAt
        elapsedBuildTime = max(0, finishedAt.timeIntervalSince(buildStartedAt))
    }

    private func formattedBuildDuration(_ duration: TimeInterval) -> String {
        let totalSeconds = max(0, Int(duration.rounded(.down)))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d小时%02d分%02d秒", hours, minutes, seconds)
        }
        if minutes > 0 {
            return String(format: "%d分%02d秒", minutes, seconds)
        }
        return "\(seconds)秒"
    }

    private func isRemoteImageURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme)
    }

    private func prepareLogFile() {
        let formatter = ISO8601DateFormatter()
        let name = "build-\(formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")) .log".replacingOccurrences(of: " ", with: "")
        currentLogFile = container.logsDirectory.appendingPathComponent(name)
        _ = FileManager.default.createFile(atPath: currentLogFile!.path, contents: Data())
    }

    private func appendLog(_ text: String) {
        logs += text
        if !logs.hasSuffix("\n") { logs += "\n" }
        if let logFile = currentLogFile, let data = text.data(using: .utf8), let handle = try? FileHandle(forWritingTo: logFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { let value = trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value }
}
