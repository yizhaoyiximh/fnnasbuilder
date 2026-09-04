import Foundation

struct Device: Identifiable, Hashable, Sendable {
    let id: String
    let model: String
    let soc: String
    let board: String
    let platform: String
    let family: String
    let description: String

    init(id: String, model: String, soc: String, board: String? = nil, platform: String, family: String = "", description: String) {
        self.id = id
        self.model = model
        self.soc = soc
        self.board = board ?? id
        self.platform = platform
        self.family = family
        self.description = description
    }
}

enum DownloadMirror: String, CaseIterable, Identifiable, Sendable {
    case official
    case aliyun
    case tsinghua
    case ustc
    case tencent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .official: return "Ubuntu 官方源"
        case .aliyun: return "阿里云镜像"
        case .tsinghua: return "清华大学 TUNA 镜像"
        case .ustc: return "中国科学技术大学镜像"
        case .tencent: return "腾讯云镜像"
        }
    }

    var detail: String {
        switch self {
        case .official:
            return "使用 Ubuntu 官方软件源；适合网络访问国际站点稳定的环境。"
        case .aliyun:
            return "使用阿里云 Ubuntu Ports 镜像，适合中国大陆网络。"
        case .tsinghua:
            return "使用清华大学 TUNA Ubuntu Ports 镜像，适合中国大陆网络。"
        case .ustc:
            return "使用中科大 Ubuntu Ports 镜像，适合中国大陆网络。"
        case .tencent:
            return "使用腾讯云 Ubuntu Ports 镜像，适合中国大陆网络。"
        }
    }

    /// Ubuntu 24.04 arm64 容器使用 Ports 仓库，而不是 amd64 的 archive 仓库。
    var aptBaseURL: String? {
        switch self {
        case .official: return nil
        case .aliyun: return "http://mirrors.aliyun.com/ubuntu-ports"
        case .tsinghua: return "http://mirrors.tuna.tsinghua.edu.cn/ubuntu-ports"
        case .ustc: return "http://mirrors.ustc.edu.cn/ubuntu-ports"
        case .tencent: return "https://mirrors.cloud.tencent.com/ubuntu-ports"
        }
    }

    /// 国内选项优先尝试 DaoCloud 的公开 Docker Hub 加速地址，失败后自动回退官方镜像。
    /// Apple Container CLI 接受标准 OCI/Docker registry reference。
    var containerImageReferences: [String] {
        switch self {
        case .official:
            return ["ubuntu:24.04"]
        default:
            return ["docker.m.daocloud.io/library/ubuntu:24.04", "ubuntu:24.04"]
        }
    }
}

enum BuildPhase: String, Sendable {
    case idle = "等待开始"
    case preparing = "准备容器环境"
    case validating = "检查输入"
    case downloading = "下载基础镜像"
    case staging = "准备基础镜像"
    case building = "正在构建固件"
    case collecting = "收集构建产物"
    case finished = "构建完成"
    case failed = "构建失败"
    case cancelled = "已取消"
}

struct BuildOptions: Sendable {
    var autoKernel = true
    var downloadMirror: DownloadMirror = .official
    var skipKernel = false
    var kernel: String? = "6.18.y"
    var rootfsExpand = "16"
    var imageSize = "512/6144"
    var builderName = ""
}

struct BuildRequest: Sendable {
    let imageURL: URL?
    let imageFile: URL?
    let device: Device
    let options: BuildOptions
    let outputDirectory: URL
}

struct BuildArtifact: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let size: Int64
}

struct BuildProgress: Sendable {
    let phase: BuildPhase
    let fraction: Double?
    init(_ phase: BuildPhase, fraction: Double? = nil) { self.phase = phase; self.fraction = fraction }
}

struct EnvironmentStatus: Sendable {
    var systemOK = false
    var appleSilicon = false
    var containerAvailable = false
    var containerMachineReady = false
    var containerPath: String?
    var appSupportURL: URL?
    var logsURL: URL?
    var freeSpace: Int64 = 0
    var message = "正在检测…"
}
