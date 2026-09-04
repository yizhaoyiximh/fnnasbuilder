import Foundation

/// 对 Apple Container CLI 的最小封装。
///
/// Apple 的签名 pkg 会把 `container` 安装在系统目录；普通 .app 既不能静默安装它，
/// 也不应绕过管理员授权。准备完成后，本服务会保留名为 `fnnas-builder` 的 Linux
/// 容器：该容器的可写层保存 apt 已安装的依赖，`workspace` 则持久挂载到 /mnt/fnnas。
final class ContainerService: @unchecked Sendable {
    static let builderImage = "ubuntu:24.04"
    static let builderContainerName = "fnnas-builder"
    private static let customKernelLabel = "fnnas-kernel=btrfs-vfat-msdos-partscan-arm64"
    /// FnNAS 构建需要较大的内存，容器上限固定为 2 GiB。
    private static let desiredMemoryInBytes: Int64 = 2 * 1024 * 1024 * 1024

    let appSupport: URL
    let logsDirectory: URL
    let workspace: URL

    private let runner = ProcessRunner()
    private let fm = FileManager.default

    init() {
        appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FnNASBuilder", isDirectory: true)
        logsDirectory = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/FnNASBuilder", isDirectory: true)
        workspace = appSupport.appendingPathComponent("workspace", isDirectory: true)

        try? fm.createDirectory(at: appSupport, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    /// Apple 的安装器通常放在 /usr/local/bin；也兼容开发环境或未来版本的 PATH。
    func containerExecutable() -> String? {
        let locations = ["/usr/local/bin/container", "/opt/homebrew/bin/container", "/usr/bin/container"]
        if let executable = locations.first(where: fm.isExecutableFile(atPath:)) {
            return executable
        }
        return (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("container").path }
            .first(where: fm.isExecutableFile(atPath:))
    }

    /// Returns the official signed installer bundled in this application, if present.
    ///
    /// The installer is opened with macOS Installer and therefore always requires explicit
    /// user/admin authorization; this app never invokes a privileged installation command.
    func bundledInstallerURL() -> URL? {
        Bundle.main.url(forResource: "apple-container-1.3.1-installer-signed", withExtension: "pkg")
    }

    func checkEnvironment() async -> EnvironmentStatus {
        var status = EnvironmentStatus()
        let version = ProcessInfo.processInfo.operatingSystemVersion
        status.systemOK = version.majorVersion >= 26
        status.appleSilicon = {
            #if arch(arm64)
            true
            #else
            false
            #endif
        }()
        status.containerPath = containerExecutable()
        status.containerAvailable = status.containerPath != nil
        status.appSupportURL = appSupport
        status.logsURL = logsDirectory

        if let volume = try? fm.attributesOfFileSystem(forPath: appSupport.path),
           let free = volume[.systemFreeSize] as? NSNumber {
            status.freeSpace = free.int64Value
        }
        if let executable = status.containerPath {
            let result = try? await runner.run(executable, arguments: ["system", "status"], onOutput: { _ in })
            status.containerMachineReady = result?.status == 0
        }

        status.message = !status.systemOK ? "需要 macOS 26 或更高版本" :
            !status.appleSilicon ? "仅支持 Apple Silicon" :
            !status.containerAvailable ? "未检测到 Apple Container 工具。可点击“安装 Apple Container…”打开内置的 Apple 官方签名安装包。" :
            status.containerMachineReady ? "Apple Container 服务已就绪" : "Apple Container 服务未启动，构建时将尝试自动启动"
        return status
    }

    /// 清理仅属于 FnNAS Builder 的持久容器和共享工作目录。
    ///
    /// 不删除 Apple Container 服务、Ubuntu 基础镜像和 App 的日志目录；前两者可能被
    /// 其他项目复用，日志则是定位构建失败所需的诊断资料。
    func clearBuildEnvironment(log: @escaping @Sendable (String) -> Void) async throws {
        log("正在清理 FnNAS Builder 持久构建容器…\n")

        if let executable = containerExecutable() {
            let inspect = try await runner.run(
                executable,
                arguments: ["inspect", Self.builderContainerName],
                onOutput: { _ in }
            )

            if inspect.status == 0 {
                let delete = try await runner.run(
                    executable,
                    arguments: ["delete", "--force", Self.builderContainerName],
                    onOutput: log
                )
                guard delete.status == 0 else {
                    throw commandError(code: 7, message: "构建容器删除失败", result: delete)
                }
                log("已删除持久构建容器。\n")
            } else {
                log("未发现持久构建容器，跳过容器删除。\n")
            }
        } else {
            log("未检测到 Apple Container 工具，跳过容器删除。\n")
        }

        log("正在清理 FnNAS Builder 工作目录…\n")
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        let contents = try fm.contentsOfDirectory(
            at: workspace,
            includingPropertiesForKeys: nil,
            options: []
        )
        for item in contents {
            try fm.removeItem(at: item)
        }
        log("构建环境清理完成。\n")
    }

    /// 启动服务、拉取 Ubuntu，并创建或恢复持久的 builder 容器。
    /// 依赖安装由 BuildService 的 bootstrap 脚本完成一次，并保存在该容器的可写层中。
    func prepareContainer(mirror: DownloadMirror = .official, log: @escaping @Sendable (String) -> Void) async throws {
        guard let executable = containerExecutable() else {
            throw ProcessRunnerError.executableNotFound("container（请先安装 Apple 官方 Container pkg）")
        }
        guard let customKernel = customKernelURL() else {
            throw NSError(
                domain: "FnNASBuilder",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "App 内置的 btrfs/vfat/MS-DOS 分区支持自定义 Linux 内核缺失，请重新下载完整的 FnNAS Builder.app。"]
            )
        }

        log("正在启动 Apple Container 服务…\n")
        // 初次启动时 Container CLI 会要求确认下载 Kata 默认内核；GUI 无法向子进程交互式输入。
        // 显式启用官方默认内核安装，才能完成真正的一键环境准备（不涉及管理员提权）。
        let startSystem = try await runner.run(
            executable,
            arguments: ["system", "start", "--enable-kernel-install"],
            onOutput: log
        )
        if startSystem.status != 0 {
            let status = try await runner.run(executable, arguments: ["system", "status"], onOutput: { _ in })
            guard status.status == 0 else {
                throw commandError(code: 1, message: "Apple Container 服务启动失败", result: startSystem)
            }
        }

        log("正在确认 Ubuntu 24.04 构建镜像（\(mirror.displayName)）…\n")
        var pull: ProcessResult?
        var imageReference = Self.builderImage
        for (index, reference) in mirror.containerImageReferences.enumerated() {
            if index > 0 { log("镜像源连接失败，正在回退到 Ubuntu 官方镜像…\n") }
            let candidate = try await runner.run(
                executable,
                arguments: ["image", "pull", "--platform", "linux/arm64", reference],
                onOutput: log
            )
            pull = candidate
            if candidate.status == 0 {
                imageReference = reference
                break
            }
        }
        guard let pull, pull.status == 0 else {
            throw commandError(code: 2, message: "Ubuntu 24.04 构建镜像拉取失败", result: pull ?? ProcessResult(status: -1, output: ""))
        }

        let inspect = try await runner.run(
            executable,
            arguments: ["inspect", Self.builderContainerName],
            onOutput: { _ in }
        )
        var needsCreate = inspect.status != 0
        var recreateReason: String?
        if !needsCreate, !hasCurrentKernelLabel(in: inspect.output) {
            recreateReason = "支持 btrfs/vfat 的自定义内核"
        } else if !needsCreate, !hasCurrentMemoryLimit(in: inspect.output) {
            recreateReason = "2 GiB 内存上限"
        }
        if let recreateReason {
            // 内核和内存都是容器创建参数，不能在已存在的容器上热切换。
            // 删除并按当前配置重建；workspace 位于宿主机挂载目录，不会丢失。
            log("检测到旧版构建容器，正在切换到支持\(recreateReason)的配置…\n")
            let remove = try await runner.run(
                executable,
                arguments: ["delete", "--force", Self.builderContainerName],
                onOutput: log
            )
            guard remove.status == 0 else {
                throw commandError(code: 5, message: "旧构建容器删除失败，无法更新容器配置", result: remove)
            }
            needsCreate = true
        }
        if needsCreate {
            log("正在创建持久构建容器（首次仅创建一次）…\n")
            var createArguments = [
                "create", "--name", Self.builderContainerName,
                "--init", "--platform", "linux/arm64",
                "--cap-add", "ALL",
                "--memory", "2g",
                "--label", Self.customKernelLabel,
                "--volume", "\(workspace.path):/mnt/fnnas"
            ]
            log("使用自定义 Linux 内核：\(customKernel.lastPathComponent)（已启用 btrfs + vfat + MS-DOS 分区扫描）\n")
            log("容器内存上限：2 GiB\n")
            createArguments += ["--kernel", customKernel.path]
            createArguments += [imageReference, "sleep", "infinity"]
            let create = try await runner.run(
                executable,
                arguments: createArguments,
                onOutput: log
            )
            guard create.status == 0 else {
                throw commandError(code: 3, message: "持久构建容器创建失败", result: create)
            }
        }

        // `start` 对已运行容器会返回非 0；这时用 exec true 判定是否实际可用。
        let startBuilder = try await runner.run(
            executable,
            arguments: ["start", Self.builderContainerName],
            onOutput: log
        )
        if startBuilder.status != 0 {
            let probe = try await runner.run(
                executable,
                arguments: ["exec", Self.builderContainerName, "true"],
                onOutput: { _ in }
            )
            guard probe.status == 0 else {
                throw commandError(code: 4, message: "持久构建容器无法启动", result: startBuilder)
            }
        }

        try await validateBuildCapabilities(executable: executable, log: log)
    }

    /// 检查现有容器是否已经按当前配置设置为 2 GiB 内存上限。
    private func hasCurrentMemoryLimit(in output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let record = records.first,
              let configuration = record["configuration"] as? [String: Any],
              let resources = configuration["resources"] as? [String: Any],
              let value = resources["memoryInBytes"] as? NSNumber else {
            return false
        }
        return value.int64Value == Self.desiredMemoryInBytes
    }

    /// `container inspect` 输出为 JSON，标签格式是 `"fnnas-kernel" : "..."`，
    /// 不是 CLI 创建时传入的 `fnnas-kernel=...` 形式，不能直接用 contains(label) 判断。
    private func hasCurrentKernelLabel(in output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let records = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return false
        }
        let expected = Self.customKernelLabel.replacingOccurrences(of: "fnnas-kernel=", with: "")
        return records.contains { record in
            guard let configuration = record["configuration"] as? [String: Any],
                  let labels = configuration["labels"] as? [String: Any] else {
                return false
            }
            return labels["fnnas-kernel"] as? String == expected
        }
    }

    /// FnNAS 基础镜像使用 DOS(MBR) 分区表，根分区为 btrfs，启动分区为 vfat。
    /// 只有文件系统驱动并不足够：`losetup -P` 还要求内核内建 MS-DOS 分区解析器，
    /// 才会创建 `/dev/loopNp1`、`/dev/loopNp2`。这里用一次临时 loop 映射进行真实预检，
    /// 避免 `renas` 在下载完成后才无诊断地重试 mount 十一次。
    private func validateBuildCapabilities(executable: String, log: @escaping @Sendable (String) -> Void) async throws {
        let script = #"""
        set +e
        missing=()
        grep -qw btrfs /proc/filesystems || missing+=(btrfs)
        grep -qw vfat /proc/filesystems || missing+=(vfat)
        loop_devices=$(ls /dev/loop* 2>/dev/null | wc -l | tr -d ' ')
        if [ "${loop_devices:-0}" -eq 0 ]; then missing+=(loop); fi

        probe_dir=$(mktemp -d /tmp/fnnas-loop-probe.XXXXXX) || missing+=(probe-workdir)
        probe_loop=""
        cleanup() {
          [ -n "${probe_loop}" ] && losetup -d "${probe_loop}" 2>/dev/null || true
          [ -n "${probe_dir}" ] && rm -rf "${probe_dir}" 2>/dev/null || true
        }
        trap cleanup EXIT

        if [ "${#missing[@]}" -eq 0 ]; then
          probe_image="${probe_dir}/partition-probe.img"
          # 不依赖 sfdisk/fdisk：首次启动时依赖尚未安装，预检本身必须可独立运行。
          # 直接写入一个最小 DOS/MBR 表（两个 1 MiB、类型 0x83 的分区）。
          # 分区起始 LBA：2048、4096；每个分区 2048 个扇区。
          dd if=/dev/zero of="${probe_image}" bs=1M count=4 status=none 2>/dev/null
          printf '\x00\x00\x02\x00\x83\xff\xff\xff\x00\x08\x00\x00\x00\x08\x00\x00\x00\x00\x02\x00\x83\xff\xff\xff\x00\x10\x00\x00\x00\x08\x00\x00' \
            | dd of="${probe_image}" bs=1 seek=446 conv=notrunc status=none 2>/dev/null
          printf '\x55\xaa' \
            | dd of="${probe_image}" bs=1 seek=510 conv=notrunc status=none 2>/dev/null
          probe_loop=$(losetup -P -f --show "${probe_image}" 2>/dev/null)
          for _ in $(seq 1 10); do
            [ -b "${probe_loop}p1" ] && [ -b "${probe_loop}p2" ] && break
            sleep 0.1
          done
          if ! [ -b "${probe_loop}p1" ] || ! [ -b "${probe_loop}p2" ]; then
            missing+=(msdos-partition-scan)
          fi
        fi

        printf 'FnNAS 容器能力检查：uid=%s，内核=%s，loop设备=%s，MS-DOS分区扫描=%s\n' \
          "$(id -u)" "$(uname -r)" "${loop_devices:-0}" \
          "$([ -n "${probe_loop}" ] && [ -b "${probe_loop}p1" ] && [ -b "${probe_loop}p2" ] && echo ready || echo unavailable)"
        if [ "${#missing[@]}" -gt 0 ]; then
          printf '缺少文件系统/设备/分区扫描支持：%s\n' "${missing[*]}"
          exit 42
        fi
        grep -E 'btrfs|vfat' /proc/filesystems || true
        """#
        let result = try await runner.run(
            executable,
            arguments: ["exec", Self.builderContainerName, "bash", "-lc", script],
            onOutput: log
        )
        guard result.status == 0 else {
            throw NSError(
                domain: "FnNASBuilder",
                code: 42,
                userInfo: [NSLocalizedDescriptionKey: "当前 Apple Container 自定义内核未完整支持 FnNAS 所需的 btrfs、vfat、loop 或 MS-DOS 分区扫描。容器虽然具备 root 和 ALL capability，但权限无法补齐缺失的内核分区解析器，因此不会生成 /dev/loopNp1、/dev/loopNp2，也无法挂载基础镜像。请使用内置的完整自定义内核重试。"]
            )
        }
    }

    private func customKernelURL() -> URL? {
        // 使用 .kernel 扩展名是为了让 Xcode 将无压缩 arm64 Image 作为普通资源复制进 .app；
        // Container CLI 依据文件内容识别内核格式，与扩展名无关。
        if let bundled = Bundle.main.url(forResource: "fnnas-vmlinux-arm64", withExtension: "kernel") {
            return bundled
        }
        // 兼容旧的开发目录布局，便于未经过 Xcode 打包时直接运行。
        let resources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources", isDirectory: true)
        let candidates = [
            resources.appendingPathComponent("fnnas-vmlinux-arm64.kernel"),
            resources.appendingPathComponent("fnnas-vmlinux-arm64")
        ]
        return candidates.first(where: { fm.fileExists(atPath: $0.path) })
    }

    /// 停止 FnNAS Builder 的持久容器，但不删除容器或其已安装的依赖。
    /// 构建完成、失败或取消后都会调用此方法，以避免容器长期占用运行资源。
    func stopBuilderContainer(log: @escaping @Sendable (String) -> Void) async {
        guard let executable = containerExecutable() else {
            log("未检测到 Apple Container 工具，跳过停止构建容器。\n")
            return
        }

        let inspect = try? await runner.run(
            executable,
            arguments: ["inspect", Self.builderContainerName],
            onOutput: { _ in }
        )
        guard inspect?.status == 0 else {
            log("未发现持久构建容器，跳过停止。\n")
            return
        }

        let stop = try? await runner.run(
            executable,
            arguments: ["stop", Self.builderContainerName],
            onOutput: { _ in }
        )
        if stop?.status == 0 {
            log("已停止 FnNAS Builder 容器（依赖和容器仍会保留）。\n")
        } else {
            // 容器可能已被用户或系统提前停止；这里不覆盖原始构建结果。
            log("FnNAS Builder 容器停止命令未成功完成，容器可能已经处于停止状态。\n")
        }
    }

    func cancel() {
        runner.cancel()
    }

    private func commandError(code: Int, message: String, result: ProcessResult) -> NSError {
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : "\n\(detail.suffix(1_500))"
        return NSError(
            domain: "FnNASBuilder",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: "\(message)（退出码 \(result.status)）\(suffix)"]
        )
    }
}
