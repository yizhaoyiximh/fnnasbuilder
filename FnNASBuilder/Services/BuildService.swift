import Foundation

final class BuildService: @unchecked Sendable {
    private static let dependencyRevision = "2026-09-01.1"
    /// Revision used when extracting the bundled FnNAS tool archive from the app.
    // Bump this revision whenever the bundled fnnas-community.tar.gz changes.
    // It makes an existing app-support cache re-extract the updated renas script.
    private static let bundledToolRevision = "2026-09-02.3"
    private static let minimumFreeSpace: Int64 = 20 * 1_024 * 1_024 * 1_024

    private let container: ContainerService
    private let runner = ProcessRunner()
    private let fm = FileManager.default

    init(container: ContainerService = ContainerService()) {
        self.container = container
    }

    func cancel() {
        runner.cancel()
        container.cancel()
    }

    func build(
        _ request: BuildRequest,
        progress: @escaping @Sendable (BuildProgress) -> Void,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> [BuildArtifact] {
        do {
            progress(BuildProgress(.validating))
        try validate(request)

        progress(BuildProgress(.preparing))
        try await container.prepareContainer(mirror: request.options.downloadMirror, log: log)

        progress(BuildProgress(.staging))
        let root = container.workspace.appendingPathComponent("build-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let source = try await stageImage(request, root: root, log: log)
        let fnnas = try locateFnNAS()
        // `renas` 以当前工作目录作为工具根目录：源码内容、fnnas-arm64/ 与
        // 它运行时创建的 fnnas/out 必须处于同一层，不能再额外套一层源码目录。
        try copyFnNASContents(from: fnnas, to: root)
        try makeBootstrapScript(root: root, mirror: request.options.downloadMirror)
        try makeBuildScript(root: root, request: request)
        log("已准备基础镜像：\(source.lastPathComponent)\n")

        let executable = try requireContainer()
        let guestRoot = "/mnt/fnnas/\(root.lastPathComponent)"

        // 安装仅在持久容器第一次运行（或依赖版本变更）时进行。
        let bootstrap = try await runner.run(
            executable,
            arguments: ["exec", "--workdir", guestRoot, ContainerService.builderContainerName,
                        "bash", "\(guestRoot)/bootstrap-environment.sh"],
            onOutput: log
        )
        guard bootstrap.status == 0 else {
            throw commandError("构建依赖安装失败", result: bootstrap)
        }

        progress(BuildProgress(.building))
        let result = try await runner.run(
            executable,
            arguments: ["exec", "--workdir", guestRoot, ContainerService.builderContainerName,
                        "bash", "\(guestRoot)/run-build.sh"],
            onOutput: log
        )
        guard result.status == 0 else {
            throw buildCommandError(result)
        }

        progress(BuildProgress(.collecting))
        try fm.createDirectory(at: request.outputDirectory, withIntermediateDirectories: true)
        let artifacts = try collectArtifacts(
            from: root.appendingPathComponent("fnnas/out", isDirectory: true),
            outputDirectory: request.outputDirectory
        )
        guard !artifacts.isEmpty else {
            throw NSError(
                domain: "FnNASBuilder",
                code: 13,
                userInfo: [NSLocalizedDescriptionKey: "构建命令已完成，但未在 fnnas/out 中找到 .img.gz 产物。请查看本次日志。"]
            )
        }

        progress(BuildProgress(.finished, fraction: 1))
        await stopBuilderContainer(log: log)
        return artifacts
        } catch {
            // 即使构建失败或被取消，也停止容器；容器本身和依赖缓存不会被删除。
            await stopBuilderContainer(log: log)
            throw error
        }
    }

    /// 在取消状态下也可靠执行停止命令，避免父任务的取消标记阻止 ProcessRunner 启动命令。
    private func stopBuilderContainer(log: @escaping @Sendable (String) -> Void) async {
        await Task.detached { [container] in
            await container.stopBuilderContainer(log: log)
        }.value
    }

    private func validate(_ request: BuildRequest) throws {
        guard !request.device.board.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw error(9, "请选择目标设备")
        }
        guard request.imageURL != nil || request.imageFile != nil else {
            throw error(10, "请选择基础镜像文件或填写下载 URL")
        }
        if let url = request.imageURL {
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? "") else {
                throw error(10, "基础镜像下载 URL 必须以 http:// 或 https:// 开头")
            }
            guard isSupportedImageName(url.lastPathComponent) else {
                throw error(11, "下载 URL 的文件名必须以 .img 或 .img.gz 结尾")
            }
        }
        if let file = request.imageFile {
            guard fm.fileExists(atPath: file.path) else { throw error(11, "基础镜像文件不存在") }
            guard isSupportedImageName(file.lastPathComponent) else { throw error(11, "基础镜像必须是 .img 或 .img.gz 文件") }
        }
        let parent = request.outputDirectory.deletingLastPathComponent()
        guard fm.fileExists(atPath: request.outputDirectory.path) || fm.isWritableFile(atPath: parent.path) else {
            throw error(12, "输出目录不可写：\(request.outputDirectory.path)")
        }

        let inputSize: Int64
        if let file = request.imageFile,
           let value = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            inputSize = Int64(value)
        } else {
            inputSize = 0
        }
        // 需要保存基础镜像副本、解压镜像、输出镜像和临时分区数据；本地输入较大时按其大小提高阈值。
        let required = max(Self.minimumFreeSpace, inputSize * 2 + 12 * 1_024 * 1_024 * 1_024)
        if let attributes = try? fm.attributesOfFileSystem(forPath: container.workspace.path),
           let free = attributes[.systemFreeSize] as? NSNumber,
           free.int64Value < required {
            throw error(14, "磁盘可用空间不足：至少需要 \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file))，当前可用 \(ByteCountFormatter.string(fromByteCount: free.int64Value, countStyle: .file))。")
        }
    }

    private func stageImage(
        _ request: BuildRequest,
        root: URL,
        log: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        let input: URL
        let sourceName: String
        if let url = request.imageURL {
            log("正在下载基础镜像…\n")
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<400).contains(statusCode) else {
                throw error(10, "基础镜像下载失败（HTTP \(statusCode)）")
            }
            input = temporaryURL
            sourceName = url.lastPathComponent
            log("已下载基础镜像\n")
        } else if let url = request.imageFile, fm.fileExists(atPath: url.path) {
            input = url
            sourceName = url.lastPathComponent
        } else {
            throw error(11, "基础镜像文件不存在")
        }

        let imageDirectory = root.appendingPathComponent("fnnas-arm64", isDirectory: true)
        try fm.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        if sourceName.lowercased().hasSuffix(".img.gz") {
            try fm.copyItem(at: input, to: imageDirectory.appendingPathComponent("base.img.gz"))
        } else {
            try fm.copyItem(at: input, to: imageDirectory.appendingPathComponent("base.img"))
        }
        return imageDirectory
    }

    private func makeBootstrapScript(root: URL, mirror: DownloadMirror) throws {
        let packages = dependencyPackages
        let aptMirrorSetup: String
        if let mirrorBase = mirror.aptBaseURL {
            aptMirrorSetup = """
            echo '正在配置 Ubuntu Ports 镜像：\(mirror.displayName)…'
            cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
            Types: deb
            URIs: \(mirrorBase)
            Suites: noble noble-updates noble-security
            Components: main universe restricted multiverse
            Architectures: arm64
            EOF
            rm -f /etc/apt/sources.list
            """
        } else {
            // Ubuntu arm64 使用 ports.ubuntu.com；显式写回官方源，避免用户从国内镜像切回官方时继续沿用旧配置。
            aptMirrorSetup = """
            echo '使用 Ubuntu 官方 Ports 软件源。'
            cat > /etc/apt/sources.list.d/ubuntu.sources <<EOF
            Types: deb
            URIs: http://ports.ubuntu.com/ubuntu-ports
            Suites: noble noble-updates noble-security
            Components: main universe restricted multiverse
            Architectures: arm64
            EOF
            rm -f /etc/apt/sources.list
            """
        }
        let httpsCertificateBootstrap: String
        if mirror.aptBaseURL?.hasPrefix("https://") == true {
            httpsCertificateBootstrap = """
            if [ ! -s /etc/ssl/certs/ca-certificates.crt ]; then
              echo '基础 Ubuntu 镜像缺少 CA 证书，正在先以 APT 签名校验方式安装 ca-certificates…'
              apt-get -o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false update
              apt-get -o Acquire::https::Verify-Peer=false -o Acquire::https::Verify-Host=false install -y --no-install-recommends ca-certificates
              update-ca-certificates
            fi
            """
        } else {
            httpsCertificateBootstrap = ""
        }
        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        # 依赖缓存只按版本标记，不按镜像源区分；切换镜像源不会触发重复安装。
        dependency_marker=/var/lib/fnnas-builder/dependencies-\(Self.dependencyRevision)

        mkdir -p /var/lib/fnnas-builder
        \(aptMirrorSetup)
        \(httpsCertificateBootstrap)
        if [ -f "$dependency_marker" ]; then
          echo '已使用持久构建容器中的 Linux 构建依赖缓存（\(mirror.displayName)）。'
          exit 0
        fi
        echo '正在通过\(mirror.displayName)在线安装 FnNAS Linux 构建依赖…'
        if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
          sed -i '/^Components:/ { /universe/! s/$/ universe/ }' /etc/apt/sources.list.d/ubuntu.sources
        elif [ -f /etc/apt/sources.list ]; then
          sed -Ei '/^[[:space:]]*deb / s/ (main)( |$)/ main universe\\2/' /etc/apt/sources.list
        fi
        apt-get update
        apt-get install -y --no-install-recommends \
        \(packages)
        touch "$dependency_marker"
        echo 'FnNAS Linux 构建依赖安装完成，并已保存到持久容器。'
        """
        try script.data(using: .utf8)!.write(to: root.appendingPathComponent("bootstrap-environment.sh"), options: .atomic)
    }

    private func makeBuildScript(root: URL, request: BuildRequest) throws {
        let options = request.options
        var arguments = ["-b", shellQuote(request.device.board), "-a", options.autoKernel ? "true" : "false", "-u", options.skipKernel ? "true" : "false"]
        let builderName = options.builderName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !builderName.isEmpty { arguments += ["-n", shellQuote(builderName)] }
        if let kernel = options.kernel?.trimmingCharacters(in: .whitespacesAndNewlines), !kernel.isEmpty { arguments += ["-k", shellQuote(kernel)] }
        if !options.rootfsExpand.isEmpty { arguments += ["-e", shellQuote(options.rootfsExpand)] }
        if !options.imageSize.isEmpty { arguments += ["-s", shellQuote(options.imageSize)] }

        let script = """
        #!/usr/bin/env bash
        set -euo pipefail
        cd "$(dirname "$0")"
        # FnNAS source dependencies are fetched by renas from their upstream repositories.
        # Existing dependency directories in the current workspace are reused by renas.
        if [ -f "fnnas-arm64/base.img.gz" ]; then
          echo '正在解压基础镜像…'
          gzip -dc "fnnas-arm64/base.img.gz" > "fnnas-arm64/base.img"
        fi
        test -s "fnnas-arm64/base.img"
        chmod +x ./renas
        ./renas \(arguments.joined(separator: " "))
        """
        try script.data(using: .utf8)!.write(to: root.appendingPathComponent("run-build.sh"), options: .atomic)
    }

    private func collectArtifacts(from output: URL, outputDirectory: URL) throws -> [BuildArtifact] {
        guard fm.fileExists(atPath: output.path) else { return [] }
        let files = try fm.contentsOfDirectory(at: output, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: .skipsHiddenFiles)
        var artifacts: [BuildArtifact] = []
        for file in files where file.lastPathComponent.hasSuffix(".img.gz") {
            guard (try file.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let destination = uniqueDestination(outputDirectory.appendingPathComponent(file.lastPathComponent))
            try fm.copyItem(at: file, to: destination)
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            artifacts.append(BuildArtifact(url: destination, size: size))
        }
        return artifacts.sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    /// Copies the *contents* of the community FnNAS tool directory to a staging root.
    /// `renas` derives `fnnas-arm64/` and `fnnas/out/` from its current directory, so
    /// copying the directory itself (for example, root/fnnas/renas) would break both paths.
    private func copyFnNASContents(from source: URL, to destination: URL) throws {
        let entries = try fm.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for entry in entries where entry.lastPathComponent != ".git" {
            try fm.copyItem(at: entry, to: destination.appendingPathComponent(entry.lastPathComponent))
        }
    }

    private func locateFnNAS() throws -> URL {
        let candidates: [URL] = [
            URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent("fnnas"),
            Bundle.main.url(forResource: "fnnas-community", withExtension: "tar.gz")
        ].compactMap { $0 }
        if let folder = candidates.first(where: { fm.fileExists(atPath: $0.appendingPathComponent("renas").path) }) { return folder }
        if let archive = candidates.first(where: { $0.pathExtension == "gz" && fm.fileExists(atPath: $0.path) }) {
            let destination = container.appSupport.appendingPathComponent(
                "fnnas-bundled-\(Self.bundledToolRevision)",
                isDirectory: true
            )
            if !fm.fileExists(atPath: destination.appendingPathComponent("renas").path) {
                try? fm.removeItem(at: destination)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                let extraction = try extract(archive: archive, destination: destination)
                guard extraction == 0 else { throw error(20, "无法解压内置 fnnas 构建工具") }
            }
            guard fm.fileExists(atPath: destination.appendingPathComponent("renas").path) else { throw error(20, "内置 fnnas 构建工具不完整") }
            return destination
        }
        throw error(20, "找不到内置 fnnas 构建工具")
    }

    private func extract(archive: URL, destination: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xzf", archive.path, "-C", destination.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private func requireContainer() throws -> String {
        guard let executable = container.containerExecutable() else { throw ProcessRunnerError.executableNotFound("container") }
        return executable
    }

    private var dependencyPackages: String {
        """
        acl aptly aria2 axel bc binfmt-support binutils-aarch64-linux-gnu bison bsdextrautils \\
        btrfs-progs build-essential busybox ca-certificates ccache clang coreutils cpio \\
        crossbuild-essential-arm64 cryptsetup curl debian-archive-keyring debian-keyring debootstrap \\
        device-tree-compiler dialog dirmngr distcc dosfstools dwarves e2fsprogs expect f2fs-tools \\
        fakeroot fdisk file flex gawk gcc-arm-linux-gnueabi gdisk git gpg gzip imagemagick jq kmod \\
        libbison-dev libc6-dev-armhf-cross libcrypto++-dev libelf-dev libfdt-dev \\
        libfile-fcntllock-perl libfl-dev libfuse-dev libgcc-12-dev-arm64-cross libgmp3-dev \\
        liblz4-tool libmpc-dev libncurses-dev libpython3-dev libssl-dev libusb-1.0-0-dev linux-base \\
        lld llvm locales lz4 lzma lzop make mtools ncurses-base ncurses-term nfs-kernel-server \\
        ntpdate openssl p7zip p7zip-full parallel parted patchutils pbzip2 pigz pixz pkg-config pv \\
        python3 python3-dev python3-setuptools qemu-user-static rdfind rename rsync sudo swig tar \\
        tree u-boot-tools udev unzip util-linux uuid uuid-dev uuid-runtime vim wget whiptail xfsprogs \\
        xsltproc xz-utils zip zlib1g-dev zstd
        """
    }

    private func isSupportedImageName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized.hasSuffix(".img") || normalized.hasSuffix(".img.gz")
    }

    private func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "FnNASBuilder", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func commandError(_ message: String, result: ProcessResult) -> NSError {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : "\n\(detail.suffix(2_000))"
        return error(Int(result.status), "\(message)（退出码 \(result.status)）。\(suffix)")
    }

    private func buildCommandError(_ result: ProcessResult) -> NSError {
        commandError("renas 构建失败。请查看日志中的最后一条 mount、losetup 或文件系统错误信息", result: result)
    }

    private func uniqueDestination(_ url: URL) -> URL {
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().deletingPathExtension().lastPathComponent
        return url.deletingLastPathComponent().appendingPathComponent("\(base)-\(UUID().uuidString).img.gz")
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
