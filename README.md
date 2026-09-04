# FnNAS Builder App

**FnNAS Builder App** 是一个面向 Apple Silicon Mac 的原生 macOS 图形化 FnNAS 固件构建工具。它将社区版 FnNAS 的 `renas` 构建流程封装到 SwiftUI 界面中，并通过 Apple Container 在本机启动一个 Ubuntu 24.04 arm64 构建环境。

使用本软件时，用户不需要单独安装 Linux 虚拟机、Homebrew、交叉编译工具链或一长串构建依赖；只需要准备基础 FnNAS 镜像，并在界面中选择目标设备和构建选项即可开始构建。


## 项目背景

[ophub/fnnas](https://github.com/ophub/fnnas) 是一个面向电视盒子及其他 ARM64 设备的 FnNAS 社区构建项目，支持 Amlogic、Rockchip、Allwinner 等平台。项目通过 `renas`、设备数据库和相关资源，为不同硬件生成可写入或启动的 FnNAS 固件。

传统的 `renas` 使用方式通常要求用户自行准备 Linux 主机，并手动安装 `btrfs`、loop device、分区工具、交叉编译工具链、压缩工具等依赖。对于只使用 macOS 的用户，这些准备工作较为繁琐，而且基础镜像挂载、分区扫描和文件系统支持容易受到运行环境差异影响。

FnNAS Builder App 的目标是提供一个可重复、可诊断的 macOS 构建入口：

- renas脚本新增“-u”参数，跳过内核替换，使用基础镜像自带内核；
- 使用 SwiftUI 提供原生 macOS 图形界面；
- 使用 Apple Container CLI 在本机运行 Ubuntu 24.04 arm64 容器；
- 使用随 App 分发的社区版 FnNAS 工具归档，其中包含 `renas` 和相关项目文件；
- 将界面中的设备、内核、分区、签名等选项转换为 `renas` 参数；
- 通过内置的 arm64 自定义 Linux 内核补齐 `btrfs`、`vfat`、loop 设备和 DOS/MBR 分区扫描支持；
- 保存完整构建日志，便于复现和排查问题。

本项目是对社区版 FnNAS 构建流程的 macOS 图形化封装和适配，并不替代 `ophub/fnnas` 上游项目。实际固件构建仍由容器内的 `renas` 脚本完成。

## 功能特性

- 启动时检查 macOS 版本、Apple Silicon 架构、`container` CLI 和 Apple Container 服务状态；
- App 资源内置 Apple 官方签名的 Container 安装包，缺少 CLI 时可从界面打开 macOS Installer 安装；
- 自动创建并复用名为 `fnnas-builder` 的持久 Ubuntu 24.04 arm64 容器；
- 容器内存上限固定为 **2 GiB**，并使用 App 内置的 btrfs/vfat 自定义内核；
- 首次构建在线安装 FnNAS 所需的 Ubuntu 依赖，安装结果缓存在持久容器中；
- 支持 Ubuntu 官方源、阿里云、清华大学 TUNA、中科大和腾讯云镜像；
- 支持选择本地 `.img`、`.img.gz` 文件，或输入 HTTP/HTTPS 下载地址；
- 选择本地基础镜像后，绝对路径会自动回填到路径输入框；
- 从 `model_database.conf` 读取目标设备列表，例如 `s922x-ct2000`；
- 支持自动采用最新内核、跳过内核替换、内核版本、根分区扩容、镜像分区大小和构建者签名；
- 构建过程中实时显示阶段、进度、已用时长和容器日志；
- 构建完成、失败或取消后自动停止 `fnnas-builder`，但不会删除容器和已安装依赖；
- 构建完成后将 `fnnas/out/*.img.gz` 复制到用户选择的输出目录，并支持在 Finder 中显示；
- 支持复制日志、打开当前日志、打开日志目录和清理构建环境。

## 系统要求

### 运行要求

- macOS **26.0 或更高版本**；
- Apple Silicon Mac（arm64，例如 M 系列芯片）；
- Apple Container CLI 和 Container 服务；
- 稳定的网络连接：首次构建需要下载 Ubuntu 软件包，`renas` 也可能下载上游 FnNAS 依赖；
- 足够的磁盘空间。App 会在构建前检查可用空间，最低要求为约 20 GiB，较大的基础镜像会使所需空间进一步增加。

### 源码构建要求

仅在从源码构建 App 时需要：

- Xcode 26 或更高版本；
- XcodeGen（用于根据 `project.yml` 生成 Xcode 工程）；
- macOS 本身提供的 `xcodebuild`、`hdiutil`、`codesign` 等工具。

最终用户运行已经打包好的 `.app` 或 `.dmg` 时，不需要安装 Xcode、XcodeGen 或 Homebrew。

## 快速开始（使用已构建版本）

1. 下载 `FnNASBuilder-1.0.0.dmg`，打开后将 **FnNAS Builder.app** 拖入 `/Applications`；
2. 启动 App，等待“运行环境”检测完成；
3. 如果提示未检测到 Apple Container，点击“安装 Apple Container…”，在 macOS Installer 中确认管理员授权，完成后返回 App 并点击“重新检测”；
4. 选择基础 `.img`/`.img.gz` 文件或填写下载 URL；
5. 选择目标设备、镜像源和构建选项；
6. 选择输出目录，点击“开始构建”；
7. 在日志区域观察构建过程，完成后在“构建产物”中查看或在 Finder 中显示输出文件。

> 当前源码脚本使用 ad-hoc 签名进行本地构建。正式对外发布时，建议使用 Developer ID Application 签名并完成 Apple notarization，否则 Gatekeeper 可能提示应用未验证。

## 从源码构建 App 和 DMG

### 1. 获取源码

```bash
git clone https://github.com/yizhaoyiximh/fnnasbuilder.git
cd fnnasbuilder
```

如果你使用的是本地源码目录，也可以直接进入包含 `project.yml` 和 `Scripts-build-dmg.sh` 的项目根目录。

### 2. 检查构建工具

```bash
xcodebuild -version
xcodegen --version
```

如果尚未安装 XcodeGen，请按照 [XcodeGen 官方项目](https://github.com/yonaskolb/XcodeGen) 的说明安装。XcodeGen 只用于开发者构建 App，不是最终用户的运行时依赖。

### 3. 构建 Release App 和 DMG

推荐直接执行项目根目录脚本：

```bash
./Scripts-build-dmg.sh
```

脚本会依次：

1. 执行 `xcodegen generate` 生成或更新 `FnNASBuilder.xcodeproj`；
2. 清理 `build-release/` 和 `dist-release/`；
3. 使用 `xcodebuild` 编译 arm64 Release App；
4. 将 App 复制到 `dist-release/`；
5. 使用 `hdiutil` 创建可分发的 DMG。

也可以进入 `FnNASBuilder/` 子目录执行同名包装脚本：

```bash
cd FnNASBuilder
./Scripts-build-dmg.sh
```

构建成功后，产物位于：

```text
dist-release/FnNAS Builder.app
dist-release/FnNASBuilder-1.0.0.dmg
```

只编译 App 而不制作 DMG 时，可以执行：

```bash
xcodegen generate
xcodebuild \
  -project FnNASBuilder.xcodeproj \
  -scheme FnNASBuilder \
  -configuration Release \
  -derivedDataPath build-release \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGN_IDENTITY=- \
  build
```

编译出的 App 位于：

```text
build-release/Build/Products/Release/FnNAS Builder.app
```

### 4. 构建验证

```bash
codesign --verify --deep --strict "dist-release/FnNAS Builder.app"
```

ad-hoc 签名只能用于本地验证和内部测试，不等同于正式 Developer ID 签名或公证。

## 使用方法

### 1. 首次启动和运行环境

App 启动后会检查：

- 当前 macOS 是否为 26.0 或更高版本；
- 当前 Mac 是否为 Apple Silicon；
- `container` 可执行文件是否存在；
- Apple Container 服务是否已启动；
- App 支持目录所在磁盘的可用空间。

如果 Container 服务尚未启动，构建时 App 会尝试自动启动。若系统中没有 `container` CLI，请使用界面提供的官方安装包完成安装。

App 内置的安装包信息：

```text
资源文件：apple-container-1.3.1-installer-signed.pkg
来源：Apple Container GitHub Release 1.3.1
SHA-256：a7c1b9d7927d30875f2f6c7bd1d0cb06c2daa6ca57ce9e90a5144e898fdf54a8
```

安装系统级组件必须由 macOS Installer 执行，并需要用户明确确认管理员授权；App 不会静默调用 `sudo` 或绕过系统授权。

### 2. 选择下载镜像源

“下载镜像源”位于“运行环境”组中，可选择：

| 选项 | Ubuntu arm64 APT 源 | 容器镜像行为 |
| --- | --- | --- |
| Ubuntu 官方源 | `ports.ubuntu.com/ubuntu-ports` | 使用 `ubuntu:24.04` |
| 阿里云镜像 | `mirrors.aliyun.com/ubuntu-ports` | 优先 DaoCloud，失败回退官方 |
| 清华大学 TUNA 镜像 | `mirrors.tuna.tsinghua.edu.cn/ubuntu-ports` | 优先 DaoCloud，失败回退官方 |
| 中国科学技术大学镜像 | `mirrors.ustc.edu.cn/ubuntu-ports` | 优先 DaoCloud，失败回退官方 |
| 腾讯云镜像 | `mirrors.cloud.tencent.com/ubuntu-ports` | 优先 DaoCloud，失败回退官方 |

这里有两个独立的下载动作：

1. **容器镜像下载**：拉取 Ubuntu 24.04 arm64 基础镜像；国内选项会优先尝试 `docker.m.daocloud.io/library/ubuntu:24.04`，失败后回退 `ubuntu:24.04`；
2. **APT 依赖下载**：容器创建后，从所选 Ubuntu Ports 源安装构建依赖。

### 3. 选择基础镜像

支持两种输入方式：

- 点击文件选择器，选择本地 `.img` 或 `.img.gz`；
- 在路径框中输入本地绝对路径，或输入 HTTP/HTTPS 下载 URL。

通过选择器选中文件后，App 会自动将绝对路径写回输入框。构建前会检查文件是否存在以及扩展名是否为 `.img` 或 `.img.gz`。

### 4. 选择目标设备

设备列表来自 App 资源中的：

```text
FnNASBuilder/Resources/model_database.conf
```

界面默认选择 `s922x-ct2000`，也可以通过搜索框按设备 ID、型号、SoC 或描述筛选。

### 5. 配置构建选项

| 界面选项 | 传递给 `renas` 的参数 | 说明 |
| --- | --- | --- |
| 自动采用最新内核 | `-a true/false` | 联网获取当前可用的最新内核。关闭时使用指定的内核版本或脚本默认逻辑。 |
| 跳过内核替换 | `-u true/false` | （ophub版本基础上新增选项）保留基础镜像中的原始内核，不替换内核。开启后不会再执行在线内核查询和下载。 |
| 内核版本 | `-k <版本>` | 例如 `6.18.y`；自动内核开启时作为备用参数。 |
| 根分区扩容 | `-e <值>` | 例如 `16`，具体含义以当前 `renas` 版本为准。 |
| 镜像分区大小 | `-s <值>` | 例如 `512/6144`，具体含义以当前 `renas` 版本为准。 |
| 构建者签名 | `-n <名称>` | 例如“飞牛”；留空时不额外传递 `-n`。 |

最终执行命令的核心形式如下：

```bash
./renas -b <设备 board> -a <true|false> -u <true|false> \
  [-n <构建者>] [-k <内核版本>] [-e <根分区扩容>] [-s <镜像分区大小>]
```

如果勾选“跳过内核替换”，这只会跳过内核替换流程；FnNAS 的其他源码依赖和 Ubuntu 软件包仍可能需要联网下载。

### 6. 选择输出目录并开始构建

默认输出目录为：

```text
~/Downloads/FnNASBuilder/
```

可以点击“更改”选择其他目录。点击“开始构建”后，App 会依次执行：

1. 校验设备、基础镜像、输出目录和磁盘空间；
2. 启动 Apple Container 服务；
3. 拉取或复用 Ubuntu 24.04 arm64 镜像；
4. 创建或恢复 `fnnas-builder` 持久容器；
5. 检查自定义内核是否具备 btrfs、vfat、loop 和 DOS/MBR 分区扫描支持；
6. 将基础镜像复制到共享工作区；
7. 解压 App 内置的社区版 FnNAS 工具归档；
8. 首次运行时在线安装 Ubuntu 构建依赖；
9. 在容器中执行 `renas`；
10. 将 `fnnas/out/*.img.gz` 复制到输出目录；
11. 保存日志并停止 `fnnas-builder` 容器。

运行时产生的任务目录类似于：

```text
宿主机：~/Library/Application Support/FnNASBuilder/workspace/build-<UUID>/
容器内：/mnt/fnnas/build-<UUID>/
```

### 7. 查看日志和产物

构建日志实时显示在 App 右侧日志区域，并同时保存到：

```text
~/Library/Logs/FnNASBuilder/build-*.log
```

构建完成后，产物区域会列出生成的 `.img.gz` 文件、文件大小和 Finder 操作按钮。若构建失败，优先查看日志最后几十行，尤其关注 `mount`、`losetup`、分区扫描、APT 或网络错误。

## 容器、依赖和缓存机制

### 持久容器

容器名称固定为：

```text
fnnas-builder
```

容器创建时使用以下关键配置：

- 基础镜像：`ubuntu:24.04`（国内镜像选项会先尝试 DaoCloud 加速地址）；
- 平台：`linux/arm64`；
- 内存上限：2 GiB；
- `--cap-add ALL`；
- App 内置自定义 arm64 Linux 内核；
- 宿主机 workspace 挂载到容器 `/mnt/fnnas`。

构建成功、失败或取消后，App 会自动**停止** `fnnas-builder`，但不会删除容器。因此下次构建通常可以直接启动并复用已经安装的依赖。

如果发现已有容器使用旧内核或旧内存配置，App 会删除并按当前配置重建。重建时宿主机 workspace 不会丢失，但容器可写层会丢失，APT 依赖需要重新安装。

### 在线安装依赖

为减小 App 体积，Linux 依赖不作为大型离线软件包内置，而是在首次构建时由容器内 `apt-get` 在线安装。依赖清单位于：

```text
FnNASBuilder/Services/BuildService.swift
```

依赖安装完成后会写入版本标记：

```text
/var/lib/fnnas-builder/dependencies-2026-09-01.1
```

只要容器没有被删除，后续构建会复用这些依赖；切换 APT 镜像源不会因为镜像源变化而重复安装。清理或重建容器后，需要重新安装。

### `renas` 的来源和执行方式

App 资源中包含：

```text
FnNASBuilder/Resources/fnnas-community.tar.gz
```

该归档来自项目附带的社区版 FnNAS 工具，解压后包含 `renas`、设备数据库及相关构建文件。环境准备完成后，App 会在共享工作区中直接执行该 `renas` 脚本，并将界面配置转换为参数传入，而不是另行实现一套独立的固件构建器。

`renas` 运行时仍可能根据自身逻辑在线获取 `ophub/u-boot`、`ophub/firmware`、`amlogic-s9xxx-armbian` 和内核等上游资源；当前工作区中已经存在的依赖目录会按脚本逻辑复用。

### 自定义 Linux 内核

App 内置内核文件：

```text
FnNASBuilder/Resources/fnnas-vmlinux-arm64.kernel
```

构建信息记录在：

```text
FnNASBuilder/Resources/custom-kernel-build-info.txt
```

当前内核为 arm64、基于 Linux 6.18.5 构建，并启用：

```text
CONFIG_BTRFS_FS=y
CONFIG_FAT_FS=y
CONFIG_MSDOS_FS=y
CONFIG_VFAT_FS=y
CONFIG_BLK_DEV_LOOP=y
CONFIG_PARTITION_ADVANCED=y
CONFIG_MSDOS_PARTITION=y
CONFIG_EFI_PARTITION=y
```

这些选项用于支持 FnNAS 镜像构建时的 btrfs/vfat 文件系统、loop 设备以及 DOS/MBR 分区解析。

## 清理构建环境

点击“清理构建环境”后，App 会删除：

- `fnnas-builder` 持久容器；
- App workspace 中的临时构建内容。

不会删除：

- Apple Container 服务；
- Ubuntu 基础镜像；
- 用户选择的基础镜像；
- 输出目录和已生成的固件；
- `~/Library/Logs/FnNASBuilder/` 日志目录；
- App 内置 FnNAS 工具缓存。

清理后下一次构建会重新创建容器并在线安装依赖。构建进行中不能点击清理按钮。

## 数据目录和项目结构

### 用户数据目录

```text
~/Library/Application Support/FnNASBuilder/
├── workspace/                         # 宿主机与容器共享的构建工作区
├── fnnas-bundled-<revision>/          # 内置 FnNAS 工具解压缓存
└── （其他运行时缓存）

~/Library/Logs/FnNASBuilder/
└── build-*.log                         # 每次构建的完整日志
```

### 源码结构

```text
FnNASBuilder/
├── project.yml                         # XcodeGen 工程配置
├── Scripts-build-dmg.sh                # 生成 App 和 DMG
├── FnNASBuilder.xcodeproj/             # 生成的 Xcode 工程
├── FnNASBuilder/
│   ├── App/                            # SwiftUI App 入口
│   ├── Models/                         # 构建请求、设备和状态模型
│   ├── Services/                       # Container、Process、构建和设备库服务
│   ├── Views/                          # SwiftUI 界面
│   ├── Assets.xcassets/                # App 图标和资源
│   └── Resources/                      # FnNAS 工具、设备库、安装包和自定义内核
├── LICENSE                             # GPL-2.0 许可证文本
└── README.md
```

## 常见问题

### 为什么首次构建很慢？

首次构建通常需要拉取 Ubuntu 24.04 arm64 镜像、创建容器、在线安装大量 Ubuntu 软件包，并由 `renas` 下载上游 FnNAS 依赖。后续构建会复用持久容器中的依赖，但不同设备、内核或源码依赖仍可能产生新的下载。

### 选择“跳过内核替换”后还会下载内核吗？

不会执行在线内核查询和内核替换。但 Ubuntu 依赖、FnNAS 源码依赖和其他构建资源仍可能需要联网下载。

### 为什么构建结束后 `fnnas-builder` 变成 stopped？

这是预期行为。App 会在构建成功、失败或取消后停止容器，以避免持续占用 CPU 和内存；容器本身不会被删除，依赖仍然保留。

### `buildkit` 容器是 App 创建的吗？

不是。`buildkit` 通常是 Apple Container 自身的系统构建服务容器，由 Container 工具管理。FnNAS Builder 只管理名为 `fnnas-builder` 的构建容器。

### 构建失败如何排查？

1. 打开 `~/Library/Logs/FnNASBuilder/` 中最新的 `build-*.log`；
2. 查看日志末尾的错误摘要；
3. 确认基础镜像存在且扩展名正确；
4. 确认磁盘空间、网络和所选镜像源可用；
5. 如果出现 `loop`、`mount`、`btrfs`、`vfat` 或分区设备错误，先尝试“清理构建环境”后重新构建；
6. 提交 Issue 时请附上脱敏后的日志末尾、macOS 版本、芯片型号和目标设备。

### 清理环境会删除我的输出文件吗？

不会。清理只删除 App 自己管理的容器和 workspace，不删除基础镜像、输出固件或日志。

### 为什么需要至少约 20 GiB 可用空间？

构建过程中可能同时存在基础镜像副本、解压后的镜像、临时分区数据、容器层和最终输出文件。基础镜像越大，实际需要的空间越多。

## 上游项目、许可证和致谢

本项目基于并适配以下开源项目和组件：

- [ophub/fnnas](https://github.com/ophub/fnnas)：FnNAS 社区版构建脚本、设备数据库和相关构建资源；
- [Apple Container](https://github.com/apple/container)：macOS 上的 Linux 容器运行环境；
- [Ubuntu](https://ubuntu.com/)：容器基础发行版及 APT 软件源；
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)：源码构建时生成 Xcode 工程。

FnNAS Builder App 及本项目中基于 `ophub/fnnas` 修改、适配或再分发的代码，遵循 **GNU General Public License v2.0（GPL-2.0）**。上游项目及第三方组件的版权归各自作者和贡献者所有，并继续遵循其原有许可证。

仓库根目录已包含完整的 `LICENSE` 文件。发布修改版本时，请继续遵守 GPL-2.0 对源码、版权声明和许可证文本的要求：

- [GPL-2.0 官方文本](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html)
- [ophub/fnnas LICENSE](https://github.com/ophub/fnnas/blob/main/LICENSE)

Apple、macOS、Apple Silicon、Ubuntu 和相关商标归其各自权利人所有。本项目不代表 Apple 或 ophub 官方，也不构成任何官方合作或授权声明。

## 免责声明

FnNAS 固件构建涉及磁盘镜像、分区表、引导文件和设备特定配置。请在构建前备份重要数据，并确认目标设备、镜像来源和写盘方式。因设备兼容性、固件刷写、网络资源变化或用户操作造成的数据损失，本项目维护者不承担责任。

如果本项目对你有帮助，欢迎在 GitHub 仓库提交 Issue、改进代码或点亮 Star。
