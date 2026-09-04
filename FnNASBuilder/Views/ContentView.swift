import SwiftUI

struct ContentView: View {
    @ObservedObject var model: BuilderViewModel

    var body: some View {
        // 使用原生 HSplitView，让配置栏与构建详情成为真正可调宽度的两栏。
        // 标题和操作放在窗口 Toolbar 中，避免标题区域被左右栏切开。
        HSplitView {
            configurationPane
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 440, maxHeight: .infinity)

            buildPane
                .frame(minWidth: 620, idealWidth: 820, maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)
        }
        .frame(minWidth: 980, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Label("FnNAS Builder", systemImage: "shippingbox.fill")
                        .font(.headline.weight(.semibold))
                    Text("在 Apple Silicon Mac 上构建 FnNAS 固件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("FnNAS Builder，在 Apple Silicon Mac 上构建 FnNAS 固件")
            }

            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: model.clearBuildEnvironment) {
                    Label(
                        model.isCleaningEnvironment ? "正在清理…" : "清理构建环境",
                        systemImage: model.isCleaningEnvironment ? "hourglass" : "trash"
                    )
                }
                .disabled(model.isRunning || model.isCleaningEnvironment)
                .help(model.isRunning ? "构建进行中，暂不能清理构建环境。" : "删除 FnNAS Builder 的持久构建容器和工作目录；不会删除基础镜像、输出文件或构建日志。")

                if model.isRunning {
                    Button("取消构建", role: .destructive) {
                        model.cancelBuild()
                    }
                    .help("停止当前构建任务")
                }
            }
        }
        .onExitCommand {
            if model.isRunning { model.cancelBuild() }
        }
        .overlay {
            if model.alertMessage != nil {
                buildAlertOverlay
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: model.alertMessage != nil)
    }

    /// 使用固定尺寸的应用内提示面板，避免长错误日志把系统 Alert 撑出屏幕。
    /// 内容区域独立滚动，面板高度始终保持与主窗口同类的稳定尺寸。
    private var buildAlertOverlay: some View {
        ZStack {
            Color.black.opacity(0.18)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.alertMessage = nil }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("构建提示")
                        .font(.title3.weight(.semibold))
                    Spacer()
                }

                ScrollView {
                    Text(model.alertMessage ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                }

                HStack {
                    Spacer()
                    Button("确定") { model.alertMessage = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(width: 760, height: 720)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.24), radius: 24, y: 10)
        }
    }

    private var configurationPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                sidebarIntro
                environmentSection
                inputSection
                outputSection
                deviceSection
                optionsSection
                buildButton
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarIntro: some View {
        Text("首次构建会准备 Ubuntu 24.04 容器并安装 Linux 依赖，过程可能需要较长时间。")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .padding(.top, 2)
            .accessibilityLabel("首次构建会准备 Ubuntu 24.04 容器并安装 Linux 依赖，过程可能需要较长时间。")
    }

    private var inputSection: some View {
        configCard(title: "基础镜像", systemImage: "externaldrive.fill") {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    TextField("输入 http(s) 下载地址或本地路径", text: $model.imageURLText)
                        .emphasizedFieldBorder()
                        .onSubmit { model.acceptTypedImagePath() }
                    Button("选择…", action: model.chooseImage)
                        .buttonStyle(.bordered)
                }

                if let inputFile = model.inputFile {
                    HStack(spacing: 7) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(inputFile.lastPathComponent).font(.callout.weight(.medium)).lineLimit(1)
                            Text(inputFile.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("移除") { model.clearImageSelection() }
                            .buttonStyle(.borderless)
                    }
                } else {
                    Text("支持 .img 和 .img.gz 文件；也可以粘贴 HTTP/HTTPS 下载地址。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let message = model.inputValidationMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var deviceSection: some View {
        configCard(title: "目标设备", systemImage: "cpu.fill") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("搜索设备型号或 SoC", text: $model.deviceSearchText)
                    .emphasizedFieldBorder()
                    .accessibilityLabel("搜索设备型号或 SoC")
                Picker("设备", selection: $model.selectedBoard) {
                    ForEach(model.filteredDevices) { device in
                        Text(device.displayName).tag(device.id)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)

                if let device = model.selectedDevice {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.description.isEmpty ? device.model : device.description)
                            .font(.callout.weight(.medium))
                            .lineLimit(2)
                        Text("板型：\(device.id)  ·  SoC：\(device.soc)  ·  平台：\(device.platform)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                } else if model.filteredDevices.isEmpty {
                    Label("没有匹配的可构建设备", systemImage: "magnifyingglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var optionsSection: some View {
        configCard(title: "构建选项", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 8) {
                optionToggle("自动采用最新内核", detail: "联网获取当前可用的最新内核", isOn: $model.autoKernel)
                optionToggle("跳过内核替换", detail: "保留基础镜像中的原始内核，不替换内核", isOn: $model.skipKernel)

                Divider()
                labeledField("内核版本", hint: model.autoKernel ? "自动内核开启时仅作为备用参数" : "例如 6.18.y", text: $model.kernel)
                labeledField("根分区扩容（GiB）", hint: "例如 16；留空表示使用脚本默认值", text: $model.rootfsExpand)
                labeledField("镜像分区大小（MiB）", hint: "例如 512/6144", text: $model.imageSize)
                labeledField("构建者签名", hint: "例如 飞牛", text: $model.builderName)
            }
        }
    }

    private var outputSection: some View {
        configCard(title: "输出目录", systemImage: "folder.fill") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(model.outputDirectory.path)
                        .font(.callout)
                        .lineLimit(2)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("更改…", action: model.chooseOutputDirectory)
                        .buttonStyle(.bordered)
                }
                Text("构建完成后，生成的 .img.gz 文件会复制到此目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var environmentSection: some View {
        configCard(title: "运行环境", systemImage: "server.rack") {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: model.environmentIsReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(model.environmentIsReady ? .green : .orange)
                    Text(model.environment.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 5) {
                        if !model.environment.containerAvailable {
                            Button("安装 Apple Container…", action: model.installAppleContainer)
                                .buttonStyle(.borderedProminent)
                        }
                        Button("重新检测") { Task { await model.refreshEnvironment() } }
                            .buttonStyle(.borderless)
                    }
                }
                if model.environment.freeSpace > 0 {
                    Text("可用磁盘空间：\(model.formattedFreeSpace)")
                        .font(.caption)
                        .foregroundStyle(model.hasLowDiskSpace ? .orange : .secondary)
                }
                if let url = model.environment.logsURL {
                    HStack(spacing: 4) {
                        Text("日志目录：\(url.path)").lineLimit(1).truncationMode(.middle)
                        Button("打开") { model.revealLogsDirectory() }.buttonStyle(.borderless)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("下载镜像源")
                    Picker("下载镜像源", selection: $model.downloadMirror) {
                        ForEach(DownloadMirror.allCases) { mirror in
                            Text(mirror.displayName).tag(mirror)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    // 单独占一行，并将按钮宽度扩展到整行。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(model.downloadMirror.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var buildButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                model.startBuild()
            } label: {
                Label(model.isRunning ? "构建进行中…" : "开始构建", systemImage: model.isRunning ? "hourglass" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("b", modifiers: [.command])
            .accessibilityLabel(model.isRunning ? "构建进行中" : "开始构建")
            .accessibilityHint(model.isRunning ? "当前正在构建 FnNAS 固件" : "使用当前配置开始构建 FnNAS 固件")
            .disabled(!model.canStartBuild)

            if !model.canStartBuild && !model.isRunning {
                Text(model.startButtonHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var buildPane: some View {
        VStack(alignment: .leading, spacing: 2) {
            // 将状态、耗时/百分比和进度条收拢为紧凑的顶部区域，避免进度条上方出现多余留白。
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.phase.rawValue).font(.title2.weight(.semibold))
                    Text(model.isRunning ? "构建日志会实时显示在下方" : "准备好后点击左侧“开始构建”")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if model.isRunning {
                    ProgressView().controlSize(.small)
                }
            }

            // 耗时和百分比与进度条保持原有相对位置，并整体紧贴状态区域。
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Spacer(minLength: 0)
                    if model.buildDurationText != "—" {
                        Text(model.buildDurationText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Text(model.progressLabel)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(model.phase == .failed ? .red : .primary)
                }

                Group {
                    if model.isRunning && model.progress <= 0 {
                        ProgressView()
                            .progressViewStyle(.linear)
                    } else {
                        ProgressView(value: model.progress)
                            .progressViewStyle(.linear)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.top, -20)

            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Label("实时日志", systemImage: "text.alignleft")
                            .font(.headline)
                        Spacer()
                        Button("复制") { model.copyLogs() }.disabled(model.logs.isEmpty)
                        Button("清空显示") { model.clearVisibleLogs() }.disabled(model.logs.isEmpty)
                        Button("打开日志文件") { model.revealCurrentLog() }.disabled(model.currentLogFile == nil)
                    }
                    .buttonStyle(.borderless)
                    .padding(.bottom, 9)
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            Text(model.logs.isEmpty ? "暂无日志。开始构建后，容器输出会实时显示在这里。" : model.logs)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(model.logs.isEmpty ? .secondary : .primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                                .id("log-bottom")
                        }
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                        )
                        .onChange(of: model.logs) { _, _ in
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("log-bottom", anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label("构建产物", systemImage: "archivebox.fill")
                            .font(.headline)
                        Spacer()
                        if !model.outputs.isEmpty { Text("共 \(model.outputs.count) 个文件").font(.caption).foregroundStyle(.secondary) }
                    }
                    if model.outputs.isEmpty {
                        Text("构建完成后，生成的 .img.gz 文件会显示在这里。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.outputs) { artifact in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.zipper").foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(artifact.url.lastPathComponent).lineLimit(1)
                                    Text(ByteCountFormatter.string(fromByteCount: artifact.size, countStyle: .file))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("在 Finder 中显示") { model.reveal(artifact) }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func configCard<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: systemImage).font(.headline)
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
        )
    }

    private func optionToggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // 独立放置开关并用 Spacer 撑满整行，使其右边缘与“更改…”按钮一致。
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(title)
                .accessibilityHint(detail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledField(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.callout.weight(.medium))
            TextField(hint, text: text).emphasizedFieldBorder()
        }
    }
}

private extension View {
    /// macOS 默认 roundedBorder 在未聚焦时颜色较浅，使用系统分隔线颜色增强可见度。
    func emphasizedFieldBorder() -> some View {
        textFieldStyle(.roundedBorder)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.9), lineWidth: 1)
            )
    }
}

private extension Device {
    var displayName: String {
        let modelName = model.isEmpty ? "未命名设备" : model
        return "\(id) · \(modelName)"
    }
}
