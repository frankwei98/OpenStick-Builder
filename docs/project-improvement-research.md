# OpenStick-Builder 项目改进研究

研究日期：2026-08-29
审查基线：`main` at `e36a47cc3949efeadeff984ef55899ec4c036a4b`

## 结论摘要

这个 fork 已经明显超过原始上游：它补上了 Debian 13、AMD64/ARM64 双宿主构建、板型 profile、克隆镜像去身份化、隔离的 USB 管理网络、组合 USB gadget、首次启动扩容和一组可运行的回归测试。当前四个测试脚本全部通过，生产脚本也全部通过 shell 语法检查。

目前最值得先做的不是继续加功能，而是收紧构建安全边界和发布可信度：

1. **P0：修复 chroot 遗留挂载与递归删除的宿主破坏风险。** `debootstrap.sh` 在挂载宿主 `/dev`、`/run` 等路径后没有退出清理 trap，却会在下次运行开始时以 root 递归删除整个 chroot。
2. **P1：替换并验证已 EOL 的 postmarketOS v24.06 内核输入。** 现在通过明文 HTTP 下载 APK，直接用 `tar` 解包并排除签名文件，没有校验下载内容。
3. **P1：提供 hardened 镜像模式。** 固定 Wi-Fi 密码、固定用户/root 密码、免密 sudo 和 USB 串口 root 自动登录叠加后，默认镜像只适合受控开发环境，不适合长期开机或交付给非开发者。
4. **P1：把快速测试变成 PR/push 必跑检查。** 两个 workflow 都仅支持手动触发；当前测试只能在人工启动完整 root 构建时被执行。
5. **P1：定义“可追溯构建”并逐步达到可复现构建。** Debian 软件包来自实时滚动的仓库，镜像时间戳、文件系统 UUID 和构建环境没有锁定，也没有发布 manifest、SHA256 或 provenance。

建议按“宿主安全 → 供应链与凭据 → CI 门禁 → 可复现性 → 文档/上游维护”的顺序实施。

## 研究范围与验证

本次只做只读审查并新增本报告，没有执行 `fetch`、`pull`、切换/创建分支、完整镜像构建或真机刷写。用户现有未跟踪 `AGENTS.md` 保持不动。

执行结果：

- `main` 与 `origin/main` 为 `0 ahead / 0 behind`；工作区原有变化只有未跟踪 `AGENTS.md`。
- `tests/test-build-host-architecture.sh`、`tests/test-image-configuration.sh`、`tests/test-openstick-board.sh`、`tests/test-openstick-modem-isolate.sh` 全部通过。
- `sh -n` / `bash -n` 覆盖所有生产脚本并通过。
- ShellCheck 可用，报告 5 个 `SC2086`（`extract_fw.sh` 未引用 `${TMPDIR}`）和 2 个 `SC2034`（`setup.sh` 的 noninteractive 变量未导出）。
- 当前 macOS 宿主没有 `systemd-analyze`，因此没有在本地完成 unit 校验；应在 Debian/Ubuntu CI 中补上。

## 已经做得好的部分

### 克隆镜像身份处理正确

构建在打包前删除 SSH host keys、清空 `/etc/machine-id`，并让 D-Bus machine-id 指回同一文件；测试还验证了脚本可重复执行（[`scripts/deidentify-rootfs.sh`](../scripts/deidentify-rootfs.sh#L31-L65)，[`tests/test-image-configuration.sh`](../tests/test-image-configuration.sh#L60-L71)）。systemd 官方说明空的 `/etc/machine-id` 会在首次启动时初始化新 ID，因此这个方向与系统机制一致（[systemd-machine-id-setup](https://www.freedesktop.org/software/systemd/man/latest/systemd-machine-id-setup.html)）。

### USB 管理面与普通网络已做隔离

USB profile 使用静态 `/30`、`never-default=true`、禁用自动 DNS；dnsmasq 只发一个租约，不下发 router/DNS option；root 密码 SSH 也限制到 USB 本地地址和主机地址组合（[`scripts/render-usb-management.sh`](../scripts/render-usb-management.sh#L123-L177)）。相关生成结果和 OpenSSH `Match` 语义已有测试（[`tests/test-image-configuration.sh`](../tests/test-image-configuration.sh#L19-L58)）。

### 板型选择从“改文件”提升为可验证操作

板型数据库集中记录 DTB、lk1st compatible 和显示名（[`configs/openstick-board-profiles`](../configs/openstick-board-profiles#L1-L3)）；选择操作检查 DTB、原子替换配置、备份和失败恢复，并有较完整的模拟测试。这解决了上游长期存在的“UZ801 与 UFI 系列 compatible 如何选择”问题（[上游 issue #1](https://github.com/kinsamanka/OpenStick-Builder/issues/1)）。

### 部分外部输入已经锁定

Debian archive keyring 固定版本并校验 SHA256（[`scripts/install_deps.sh`](../scripts/install_deps.sh#L3-L5)，[`scripts/install_deps.sh`](../scripts/install_deps.sh#L54-L61)）；DragonBoard bootloader ZIP 也有固定 SHA256 和双下载源（[`scripts/extract_fw.sh`](../scripts/extract_fw.sh#L4-L17)）。Git submodule 由父仓库 gitlink 固定到具体提交。这些模式应推广到内核和发布物。

## 详细改进项

### P0 — 构建失败后重跑可能沿 bind mount 删除宿主文件

**证据**

- `debootstrap.sh` 在创建新 rootfs 前执行 `rm -rf -- "${CHROOT}"`（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L59-L70)）。
- 随后 bind mount 宿主 `/dev`、`/dev/pts`、`/run`，并挂载 proc/sysfs（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L92-L96)）。
- 卸载只出现在成功路径末尾，没有 `EXIT/HUP/INT/TERM` trap（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L98-L113)）。如果 `setup.sh`、网络、APT 或后续命令失败，挂载会遗留。
- GNU Coreutils 的 `rm --one-file-system` 文档明确以“忘记卸载 build chroot 后执行 `rm -rf`，从而删除 bind-mounted `/home`”作为典型危险示例（[GNU Coreutils: `rm` invocation](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html)）。这里的 `/dev` 和 `/run` 同属这一风险类型。
- `build_images.sh` 对 `boot.raw` 和 `rootfs.raw` 的挂载同样没有失败清理 trap（[`scripts/build_images.sh`](../scripts/build_images.sh#L5-L25)）。

**建议**

1. 在任何删除之前用 `findmnt -R --target "${CHROOT}"` 检查子挂载；存在挂载时拒绝删除并给出恢复命令。
2. 建立 LIFO cleanup trap，记录每个成功挂载，只逆序卸载已经挂载的路径；处理 `EXIT HUP INT TERM`，保留原退出码。
3. 把 `rm -rf` 改为 `rm -rf --one-file-system --preserve-root=all -- "${CHROOT}"`。这不是 trap 的替代品，但能增加第二道保护。
4. 更强的方案是在私有 mount namespace 中执行 chroot 构建，并将挂载设为 private，防止传播；Linux `mount` 文档说明 bind mount 会把同一目录树附加到另一个位置（[mount(8)](https://man7.org/linux/man-pages/man8/mount.8.html)）。
5. 新增失败注入测试：让 chroot/setup 在每个阶段失败，断言所有挂载都被清理、原退出码保留、下次运行不会删除挂载内容。

### P1 — 内核输入未验证且来自已结束支持的发行分支

**证据**

- 构建通过明文 HTTP 下载 `linux-postmarketos-qcom-msm8916-6.6-r5.apk`，直接解包到 rootfs，并显式排除 `.SIGN*`，没有 SHA256 或 APK signature 验证（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L168-L170)）。
- README 推荐的设备内核升级命令复制了同样的 HTTP + 忽略签名流程（[`README.md`](../README.md#L233-L237)）。
- postmarketOS 包索引显示该包构建于 2024-05-30、版本为 6.6-r5（[postmarketOS package index](https://pkgs.postmarketos.org/package/v24.06/postmarketos/aarch64/linux-postmarketos-qcom-msm8916)）。postmarketOS 的官方 release 表已把 v24.06 列入 End of Life，而更新分支已有 MSM8916 6.12 系列（[postmarketOS releases](https://docs.postmarketos.org/pmaports/main/releases.html)）。

**建议**

1. 先在 UFI003、UZ801 上建立内核升级验收矩阵：启动、eMMC、Wi-Fi AP、USB composite、QMI/ModemManager、充电、电源键、首次扩容。
2. 选择仍受支持且通过真机验证的 postmarketOS 分支/包；不要仅追“最新”。把 branch、版本、URL、SHA256 集中到版本清单。
3. 使用 HTTPS 下载到临时文件，再验证仓库签名或仓库内固定 SHA256，验证后才解包；失败时不得留下半写 rootfs。
4. 删除 README 中不验证签名的在线更新范例，改为版本化、可回滚的内核升级流程，并说明 DTB/kernel ABI 配套关系。
5. 长期可考虑从固定 source commit/config 构建内核，或至少保存 APK、上游 commit、包元数据和许可证到 build manifest。

### P1 — 默认凭据组合只适合受控开发环境

**证据**

- root 密码固定为 `1`；普通用户密码同样固定为 `1`，且获得 `NOPASSWD: ALL`（[`scripts/setup.sh`](../scripts/setup.sh#L43-L46)）。
- Wi-Fi AP 使用公开固定 PSK `openstick`（[`configs/hotspot.nmconnection`](../configs/hotspot.nmconnection#L7-L21)）。
- USB ACM 直接 root 自动登录（[`configs/system/getty@ttyGS0.service`](../configs/system/getty@ttyGS0.service#L7-L18)）；板载 `ttyMSM0` serial-getty 也覆盖为 root 自动登录（[`configs/system/serial-getty@ttyMSM0.service.d/override.conf`](../configs/system/serial-getty@ttyMSM0.service.d/override.conf#L1-L3)）。
- USB endpoint 对 root 密码 SSH 的限制设计是合理的，但普通 `user` 仍可通过其他可达接口登录后免密提权。
- README 披露了 Wi-Fi 和普通用户密码，但没有在同一安全提示中披露 root 密码、免密 sudo 和 USB root console（[`README.md`](../README.md#L167-L185)）。本地实施规格说明这些是开发板便利性决策（[`docs/longqt-useful-port-spec.md`](longqt-useful-port-spec.md#L54-L72)），因此问题是默认产品模式和文档，而不是单独把 ACM 认定为 bug。

**建议**

- 明确定义 `development` 与 `hardened` 两个镜像 profile。开发模式保持现有救援体验，但启动横幅/README 明示风险；hardened 模式禁用 root 自动登录、禁止密码 SSH、取消免密 sudo并要求注入 SSH 公钥。
- 首次启动生成唯一 Wi-Fi PSK/用户密码，或强制改密后再启用 Wi-Fi/LTE 网络；不要把固定密码用于可长期部署镜像。
- 至少让普通用户的密码认证只在 USB 管理面可用，避免已知 Wi-Fi PSK + 已知用户密码 + 免密 sudo 构成完整远程 root 路径。
- 为配置文件增加文件权限和最终 `sshd -T -C ...`/NetworkManager 行为测试。

### P1 — 构建不可复现，且缺少足够的构建记录

**证据**

- debootstrap 和 rootfs 中的 `apt update/upgrade/install` 都读取实时 Debian 仓库，没有 snapshot timestamp 或包版本锁（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L72-L90)，[`scripts/setup.sh`](../scripts/setup.sh#L12-L39)）。同一 Git commit 在不同日期会得到不同包集合。
- `tar cpzf`、`mkfs.ext2`、`mkfs.ext4` 没有统一时间、排序或 UUID；文件系统和归档会携带当前时间/随机标识（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L193-L197)，[`scripts/build_images.sh`](../scripts/build_images.sh#L9-L20)）。
- `SOURCE_DATE_EPOCH`、固定 locale/时区、包清单、构建器镜像 digest 和最终 SHA256 manifest 都不存在。
- Debian 官方 snapshot 服务允许用时间戳访问历史仓库状态（[snapshot.debian.org](https://snapshot.debian.org/)）；Debian 的可复现构建建议包括避免实时时间、固定 locale 并使用 `SOURCE_DATE_EPOCH`（[Debian debmake: Reproducible build](https://www.debian.org/doc/manuals/debmake-doc/ch10.en.html#reproducible-build)）。

**建议**

分两阶段，不要一开始就承诺整个镜像 byte-for-byte 相同：

1. **先达到可追溯构建**：产出 `build-manifest.json`，记录仓库 commit、dirty 状态、全部 submodule commit、构建宿主镜像/架构、Debian snapshot、已安装包及版本、内核和 bootloader 输入哈希、板型 profile、每个输出文件 SHA256。
2. **再达到可复现构建**：从 Git commit 派生 `SOURCE_DATE_EPOCH`；固定 `LC_ALL=C.UTF-8`/`TZ=UTC`；排序 tar 输入并归一化 mtime/owner；明确 ext2/ext4 UUID、hash seed 和 lazy-init 行为；固定 Debian snapshot 与构建工具版本；在 AMD64 与 ARM64 各重复构建并用 diffoscope 分析差异。
3. 允许单独的“security refresh”任务更新 snapshot/内核并生成 reviewable lockfile diff，避免“可复现”变成“永不更新”。

### P1 — CI 没有在代码变更时提供门禁

**证据**

- AMD64 和 ARM64 workflow 都只有 `workflow_dispatch`（[`.github/workflows/build.yml`](../.github/workflows/build.yml#L1-L18)，[`.github/workflows/build-arm64.yml`](../.github/workflows/build-arm64.yml#L1-L18)）。
- 四个快速回归测试虽然已接入 workflow，但只有人工启动完整构建才运行（[`.github/workflows/build.yml`](../.github/workflows/build.yml#L27-L33)）。
- workflow 没有显式 `permissions`、`timeout-minutes` 或 `concurrency`；`actions/checkout@v4` 和 `upload-artifact@v4` 使用可移动 tag，而不是完整 commit SHA（[`.github/workflows/build.yml`](../.github/workflows/build.yml#L22-L25)，[`.github/workflows/build.yml`](../.github/workflows/build.yml#L52-L56)）。GitHub 说明完整 commit SHA 是把 action 当作不可变版本使用的唯一方式（[GitHub Actions secure use](https://docs.github.com/en/actions/reference/security/secure-use)）。

**建议**

1. 新建无需 root 的 `pull_request` + `push` 快速 workflow：现有四个测试、ShellCheck、所有脚本语法检查、配置生成测试和 `systemd-analyze verify`。GitHub 官方支持在 `pull_request` 的 opened/synchronize/reopened 时运行检查（[events that trigger workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#pull_request)）。
2. 继续把昂贵的完整镜像构建保留为手动、定时或 release workflow；至少每周构建 generic/ufi003/uz801，并保存失败日志。
3. 在 workflow 顶层显式设置 `permissions: contents: read`；需要 attestation 的 release job 再最小化增加 `id-token: write` 与 `attestations: write`。
4. 将 actions 固定到经核验的完整 SHA，并让 Dependabot 维护更新；增加 job timeout 和同分支 concurrency cancellation。
5. 把两套工作流的共同构建步骤收敛到仓库脚本或 reusable workflow，避免 AMD64/ARM64 校验漂移。当前只有 ARM64 workflow 做架构、ELF、依赖、文件集合和大小验证（[`.github/workflows/build-arm64.yml`](../.github/workflows/build-arm64.yml#L58-L92)），AMD64 workflow 构建后直接上传（[`.github/workflows/build.yml`](../.github/workflows/build.yml#L49-L56)）；应让两条路径调用同一验证脚本。

### P1 — 发布固件缺少完整性与来源证明

**证据**

两个 workflow 直接上传 `files/*`，没有 SHA256 清单、版本信息、SBOM、签名或 provenance（[`.github/workflows/build.yml`](../.github/workflows/build.yml#L49-L56)，[`.github/workflows/build-arm64.yml`](../.github/workflows/build-arm64.yml#L79-L98)）。对需要刷 bootloader/partition table 的产物，用户无法独立核对下载内容与源码/构建任务的关联。

**建议**

- artifact 内至少包含 `SHA256SUMS`、上述 build manifest、许可证清单和简短刷机说明；artifact 名加入短 commit 与板型。
- release 构建生成 GitHub artifact attestation；GitHub 官方说明 attestation 会把 artifact 与 workflow、repository、commit SHA 和触发事件关联，并可附 SBOM（[GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)）。
- README 给出校验命令；刷机前脚本校验 manifest、文件集合和大小，不能只检查文件存在。

### P1 — 跨板型/重复构建可能复用不兼容的旧产物

**证据**

- `build_hyp_aboot.sh` 没有 clean 或独立输出目录，并且每次都向 lk2nd submodule 的 makefile 追加同一行（[`scripts/build_hyp_aboot.sh`](../scripts/build_hyp_aboot.sh#L9-L17)）。`OPENSTICK_BOARD` 改变时，`LK2ND_COMPATIBLE` 也会改变，但普通 Make 不会自动把命令行变量变化视为目标过期条件；旧 `emmc_appsboot.mbn` 因此有被当作“最新”复用的风险。
- `build_gt.sh` 将安装结果累积到全局 `dist/`，只清空 `build/*`，没有先清空 `dist/`（[`scripts/build_gt.sh`](../scripts/build_gt.sh#L36-L67)）。
- `build_images.sh` 只删除 `rootfs.raw` 和 `boot.raw`，不清空 `files/`（[`scripts/build_images.sh`](../scripts/build_images.sh#L5-L7)）；workflow 最后上传 `files/*`。本地迭代构建若某一步跳过、失败或不再生成某个文件，旧文件仍可能进入 artifact。
- CI 的全新 checkout 降低了官方 workflow 中的概率，但 README 明确支持逐阶段本地运行，因此本地路径必须有同等正确性。

**建议**

1. 每次完整构建使用按 commit、board、host architecture 隔离的输出目录，例如 `out/<commit>/<board>/<arch>/`；不要让 generic/ufi003/uz801 共用同一 `build/`、`dist/`、`files/`。
2. 每个 stage 在开始前清理或拒绝不匹配的输出，并写入 input stamp（source/submodule commits、board、toolchain、rootfs manifest）。只有 stamp 完全一致才允许增量复用。
3. lk2nd 使用 out-of-tree build/明确 clean，或让目标依赖包含 compatible 配置；补一个连续构建 `ufi003 → uz801 → generic` 的测试，核对各自 aboot 与 manifest。
4. 上传 artifact 前只允许 manifest 列出的文件，验证它们都由当前 run 创建并校验 SHA256。

### P2 — 构建脚本的幂等性和 noninteractive 设置需要修正

**证据**

- 每次运行 `build_hyp_aboot.sh` 都向 submodule 中的 makefile 追加同一行，重复运行会重复写入并永久弄脏 submodule（[`scripts/build_hyp_aboot.sh`](../scripts/build_hyp_aboot.sh#L9-L17)）。
- `DEBIAN_FRONTEND` 和 `DEBCONF_NONINTERACTIVE_SEEN` 只是 shell 变量，没有 `export`；ShellCheck 因其未被当前 shell 使用而报告 `SC2034`（[`scripts/setup.sh`](../scripts/setup.sh#L1-L9)）。APT 子进程因此不能从环境继承它们。
- `extract_fw.sh` 有 5 处未引用 `${TMPDIR}`；虽然 `mktemp -d` 的默认结果通常没有空格，但这不符合仓库自己的 quoting 规范（[`scripts/extract_fw.sh`](../scripts/extract_fw.sh#L23-L26)，[`scripts/extract_fw.sh`](../scripts/extract_fw.sh#L50-L55)）。

**建议**

- 把 lk2nd 修改做成仓库内版本化 patch，并用 `git apply --check`/反向检查保证只应用一次；更理想是通过 make 参数传值，不修改 submodule 工作树。
- `export DEBIAN_FRONTEND=noninteractive DEBCONF_NONINTERACTIVE_SEEN=true`，并用伪终端/超时测试证明全构建无交互。
- 把 ShellCheck 加入 CI；按现有规范修复所有无引号展开。
- 对每个 build stage 定义输入、输出、是否可安全重跑和清理策略；`build.sh` 应在开头做 prerequisites/preflight，而不是运行到中途才暴露状态问题。

### P2 — 测试覆盖没有跟上新增运行时功能

现有测试主要覆盖 host architecture、USB/SSH 配置渲染、board selector 和 modem isolation。没有发现针对以下路径的测试：

- `openstick-usb-gadget.sh` 的创建、部分失败清理、已有 UMS 数据保留、并发锁和 stop/restart；
- `openstick-resize-rootfs.sh` 的 marker/锁/错误路径；
- debootstrap/build_images 的挂载失败清理；
- bootloader/kernel 下载的哈希/签名失败；
- systemd unit 依赖与命令路径；
- GPT、extlinux PARTUUID、sparse image 大小之间的一致性；
- 真机 UFI003/UZ801 的 USB、Wi-Fi、modem、充电和恢复启动。

建议优先围绕失败边界做测试，而不是追求 shell 行覆盖率。对 configfs、sysfs、`findmnt`、`mount`、`umount`、`resize2fs` 使用临时目录和命令 stub；对 systemd 配置使用 Debian 13 容器里的 `systemd-analyze verify`；真机验收保留人工 checklist 并把内核/板型/结果记录为构建附件。

### P2 — rootfs 依赖需要按产品范围审计

`setup.sh` 安装 `bridge-utils`、`iptables`、`wireguard-tools`、`netcat-traditional`、`net-tools` 等包（[`scripts/setup.sh`](../scripts/setup.sh#L15-L39)），仓库代码中没有发现对应使用点；实施规格又明确不引入 bridge、NAT、VLAN 或 forwarding（[`docs/longqt-useful-port-spec.md`](longqt-useful-port-spec.md#L73-L78)）。

不应在没有真机验证的情况下直接删除，但可以通过 `apt-mark showmanual`、启动日志和功能矩阵逐项确认。删除无用途包可减少镜像体积、CVE 面和构建变动源；如果 NetworkManager 的 Wi-Fi shared 模式确实依赖其中某项，则应在 package list 旁记录原因并测试其外部行为。

### P2 — README 已经与实现漂移

至少存在这些可证实的不一致：

- clone 命令仍指向原始上游，而不是当前 fork（[`README.md`](../README.md#L36-L40)）。如果 fork 面向他人发布，应改为 fork URL，并另列 upstream。
- README 仍写 USB 地址 `192.168.5.1`（[`README.md`](../README.md#L176-L178)），实际配置是 `172.30.255.1/30`（[`configs/usb-management.conf`](../configs/usb-management.conf#L5-L10)）。
- README 仍指导手工 `resize2fs`（[`README.md`](../README.md#L228-L231)），镜像已默认启用首次启动扩容 service（[`scripts/debootstrap.sh`](../scripts/debootstrap.sh#L155-L156)）。
- 内核更新示例不验证下载，见上文。
- 没有集中说明 USB ACM/UMS/RNDIS、root 密码策略、UMS 数据保留、modem isolation 开关和 generic fallback 的安全边界。
- `docs/longqt-useful-port-spec.md` 仍把自己描述为 `codex/longqt-useful` 的实施规格，而相关功能已经进入 `main`；应标注“已实现/历史决策”，并把未完成验收项移到 issue/checklist。

建议将 README 拆为快速开始、构建、安装/恢复、安全模型、板型支持和 troubleshooting，避免一个文件同时承担实现规格与用户手册。

### P2 — fork 与 upstream 的同步状态不透明

**当前状态**

- 仓库配置了 `upstream` remote，但本地没有 `refs/remotes/upstream/main`，因此在禁止 fetch 的本次审查中不能用 Git 精确计算 ahead/behind。
- 本地历史包含上游 `6039097`（2026-02-02）并在其后增加 33 个 fork commit。
- 上游在线历史目前有 16 个 commit，最新为 `5724497`（2026-08-06，“Fix for missing Qualcomm firmware”）（[upstream commit history](https://github.com/kinsamanka/OpenStick-Builder/commits/main/)）。上游当前 `extract_fw.sh` 只是把 bootloader 来源改到 archive.org，并继续使用相同 SHA256（[upstream `extract_fw.sh`](https://github.com/kinsamanka/OpenStick-Builder/blob/main/scripts/extract_fw.sh#L1-L57)）。本 fork 已用同一 SHA256、主/备用双源、下载后校验和保留退出码的 cleanup 更完整地覆盖了这个问题（[`scripts/extract_fw.sh`](../scripts/extract_fw.sh#L3-L19)，[`scripts/extract_fw.sh`](../scripts/extract_fw.sh#L57-L66)）；不建议机械 cherry-pick `5724497`。可以把 archive.org 评估为第三备用源，并在 `UPSTREAM.md` 中把该 commit 标为“已等价覆盖”。

**建议**

- 增加 `UPSTREAM.md`，记录 upstream URL、fork 基线 commit、最后审查日期、已移植/拒绝的 upstream commit 及理由。
- 定期运行只读 compare workflow，发现上游新 commit 时开 issue 或生成报告，不自动 merge。fork 改动已很深，建议逐提交重实现/移植。
- 对外 README 使用 fork clone URL，同时保留“Based on kinsamanka/OpenStick-Builder”与差异说明。
- 集中版本/来源清单，让上游仅改下载 URL 时可以容易比较同一 SHA256，而不必读完整脚本。

## 建议实施路线

### 第一阶段：立即修复

1. 为 `debootstrap.sh` 和 `build_images.sh` 加挂载清理 trap、遗留挂载拒绝和删除防护，并写失败注入测试。
2. 将内核下载改为 HTTPS + 强校验；删除 README 中不安全更新命令。
3. 导出 noninteractive 环境，修复 ShellCheck 结果；让 lk2nd patch 幂等。
4. 更新 README 的 USB 地址、自动扩容、fork URL和完整默认凭据警告。

### 第二阶段：建立质量门禁

1. PR/push 快速 CI：测试、ShellCheck、语法、unit verify。
2. 明确 workflow 最小权限、action SHA、timeout/concurrency。
3. 增加 USB gadget、resize、mount cleanup、下载失败和镜像布局测试。
4. 为所有 artifact 生成 SHA256SUMS 和 build manifest。

### 第三阶段：面向可靠发布

1. 真机验证支持中的 postmarketOS 内核并升级离开 v24.06。
2. 实现 development/hardened 镜像 profile。
3. 锁 Debian snapshot，归一化时间/UUID/归档，做双宿主重复构建差异分析。
4. 发布时生成 provenance attestation/SBOM，并维护 upstream 审查记录。

## 验收指标

- 任一 chroot/build-image 阶段被 `SIGTERM` 或命令失败打断后，`findmnt -R` 不再显示构建目录挂载；重跑不会触碰宿主 bind mount 内容。
- 所有网络下载要么由仓库签名验证，要么由仓库内固定的强哈希验证；日志显示来源、版本和哈希。
- PR 修改 shell/config/unit 时自动运行快速检查；主分支不能合并失败检查。
- 每个发布 artifact 都包含 commit、submodule、package、input/output hash 和板型信息，并可验证 provenance。
- hardened 镜像不存在已知固定登录密码、网络可达的免密提权路径或 root 自动登录。
- 同一 lock manifest 重建时，包版本完全一致；最终镜像若尚未 byte-identical，差异有机器可读报告。
- README 中的地址、凭据、板型、扩容和更新流程与生成镜像的实际配置一致。

## 主要一手资料

- [kinsamanka/OpenStick-Builder upstream](https://github.com/kinsamanka/OpenStick-Builder)
- [Upstream commit history](https://github.com/kinsamanka/OpenStick-Builder/commits/main/)
- [postmarketOS releases and EOL table](https://docs.postmarketos.org/pmaports/main/releases.html)
- [postmarketOS MSM8916 v24.06 package metadata](https://pkgs.postmarketos.org/package/v24.06/postmarketos/aarch64/linux-postmarketos-qcom-msm8916)
- [Debian snapshot archive](https://snapshot.debian.org/)
- [Debian reproducible-build guidance](https://www.debian.org/doc/manuals/debmake-doc/ch10.en.html#reproducible-build)
- [GNU Coreutils `rm` safety guidance](https://www.gnu.org/software/coreutils/manual/html_node/rm-invocation.html)
- [systemd special targets, including `usb-gadget.target`](https://manpages.debian.org/trixie/systemd/systemd.special.7.en.html)
- [GitHub Actions secure-use guidance](https://docs.github.com/en/actions/reference/security/secure-use)
- [GitHub artifact attestations](https://docs.github.com/en/actions/concepts/security/artifact-attestations)
