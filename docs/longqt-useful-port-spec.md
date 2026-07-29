# LongQT 有用改动移植规格

## 状态

- 基线：从 `origin/main` 创建的 `codex/longqt-useful` 分支。
- 参考来源：`longqt-sea/main`。
- 文档性质：本地实施规格，不发布到外部 issue tracker。
- 目标设备定位：开发板，而不是通用路由器。
- 合并策略：按功能重新实现和修正，不整体合并或机械 cherry-pick LongQT 的提交。

## Problem Statement

`origin/main` 提供了基本的 Debian、蜂窝网络、Wi-Fi 和 USB gadget 构建能力，但开发板日常调试仍需要更直接的物理访问、稳定的 USB 网络管理通道、可读写的 USB 存储，以及适合克隆镜像的首次启动初始化。

`longqt-sea/main` 已经实现了其中一部分能力，但同时加入了完整路由器网络栈、DNSProxy、NAT、桥接和若干硬件假设。直接继承整个 fork 会引入与当前产品定位无关的复杂性，以及已经识别出的启动竞态、不可复现下载和配置缺陷。

本任务需要从 LongQT 的实现中提取适合开发板的部分，并根据已确认的产品行为重新实现。

## Solution

在保留 `origin/main` 构建结构和 Debian 13 行为的前提下，提供三条相互独立的开发板访问通道：

| 通道 | 用途 | 地址或介质 | root 认证 |
|---|---|---|---|
| USB ACM 串口 | 救援、底层调试 | `ttyGS0` | 自动登录，无认证 |
| USB RNDIS 网络 | SSH 和文件传输 | 开发板 `172.30.255.1/30` | 初始密码 `1` |
| USB Mass Storage | 与主机交换文件 | 100MB exFAT，卷标 `OPENSTICK` | 不适用 |

RNDIS 使用独立的点对点管理子网，不接入桥、不提供默认路由或 DNS，也不转发其他网络流量。UMS 只在首次创建镜像时格式化，已有镜像及用户数据必须保留。

同时移植适合不可变镜像和开发板使用的首次启动能力：SSH host key 与 machine-id 初始化、rootfs 扩容、防止电源键误关机，以及可选且不阻塞启动的 modem 接口整理。

## User Stories

1. 作为开发者，我希望插入 USB 后直接获得 root 串口，以便在网络尚未工作时调试设备。
2. 作为开发者，我希望 USB 串口无需用户名或密码，以便快速进行开发板救援。
3. 作为开发者，我希望电脑通过 RNDIS 自动获得地址，以便无需手工配置主机网络。
4. 作为开发者，我希望通过 `ssh root@172.30.255.1` 登录，以便使用熟悉的远程 shell 和文件传输工具。
5. 作为开发者，我希望 root SSH 使用明确的初始密码，以便网络登录不会接受空密码。
6. 作为开发者，我希望 root 密码登录仅适用于 USB 管理地址，以免 Wi-Fi 或 LTE 暴露同样的开发入口。
7. 作为电脑用户，我希望 USB 网络不修改默认路由，以免插入开发板后中断原有互联网连接。
8. 作为电脑用户，我希望 USB 网络不提供 DNS，以免系统解析流量被开发板接管。
9. 作为维护者，我希望 USB 管理子网集中配置，以便遇到 VPN、容器或企业网络冲突时只修改一处。
10. 作为开发者，我希望设备同时暴露一个可直接识别的 exFAT U 盘，以便交换日志、配置和固件。
11. 作为开发者，我希望 UMS 镜像可写且内容跨重启保留，以便把它当作持久交换区。
12. 作为设备所有者，我希望升级后已有 UMS 镜像不会被重新格式化，以免丢失数据。
13. 作为镜像维护者，我希望每台设备首次启动时生成自己的 machine-id 和 SSH host key，以免克隆设备共享身份。
14. 作为设备所有者，我希望 rootfs 首次启动时扩展到实际分区容量，以便使用全部存储空间。
15. 作为开发者，我希望短按电源键不会意外关闭设备，以免调试过程被中断。
16. 作为不同硬件版本的维护者，我希望 modem 整理逻辑只操作实际存在的接口，以免固定接口名破坏其他设备。
17. 作为维护者，我希望 modem 整理失败不会阻塞系统启动，并且可以通过配置完全关闭。
18. 作为刷机用户，我希望保留 origin 的初始 Wi-Fi 凭据，以便首次启动后能够进入设备。
19. 作为构建维护者，我希望不引入 DNSProxy、NAT 和路由桥，以便固件职责保持在开发板管理而非路由器功能。

## Implementation Decisions

### USB gadget

- 使用一个组合 USB gadget，保留 RNDIS，并增加 ACM 与 UMS。
- ACM 默认启用，提供 `ttyGS0` root 自动登录。该行为是开发板的明确产品决策，不作为安全缺陷处理。
- RNDIS 只承担主机与开发板之间的直接管理连接，不自动加入任何 bridge。
- 不启用 ECM 或 NCM。
- UMS 默认启用，容量为 100MB，可写，卷标为 `OPENSTICK`。
- 新建 UMS 镜像时使用 exFAT；为此 rootfs 需要提供 `exfatprogs`。
- 已存在的 UMS 镜像不得自动格式化。若其格式未知或损坏，只记录清晰错误，不清除内容。
- gadget 启动过程必须能够识别部分失败，并向 systemd 返回失败状态，避免残缺配置被当作成功。

### USB 管理网络

- 使用 RFC 1918 私有子网 `172.30.255.0/30`。
- 开发板固定使用 `172.30.255.1`。
- USB 主机通过 DHCP-only 获得唯一地址 `172.30.255.2`。
- 子网掩码为 `255.255.255.252`。
- DHCP 响应不得提供默认网关。
- DHCP 响应不得提供 DNS server。
- DNS 服务端口必须关闭；允许复用系统已有的轻量服务程序，但只能启用其 DHCP 能力。
- 不启用 NAT、NAT66、IP forwarding、DNS 重定向、bridge 或 VLAN。
- 地址与 DHCP 参数集中存放在一个面向维护者的配置入口中，避免散落到多个脚本和 unit。

### SSH 认证

- root 初始密码为 `1`。
- 禁止空密码网络登录。
- root 密码登录只允许目标地址为 USB 管理地址 `172.30.255.1` 的连接。
- Wi-Fi 和 LTE 地址不得继承 USB 专用的 root 密码登录策略。
- USB ACM 串口继续自动登录 root，不受 SSH 认证策略影响。
- 普通用户及其现有初始密码、sudo 行为保持 origin 语义，除非实现 USB root 登录所必需，否则不重写用户管理。

### 首次启动与系统行为

- 构建镜像时清除会导致克隆设备共享身份的 machine-id 和 SSH host key。
- 首次启动时生成新的 machine-id 和 SSH host key。
- 首次启动时将 ext4 rootfs 扩展到 rootfs 分区容量；重复启动不得重复执行破坏性操作。
- 忽略电源键触发的自动关机，但不改变显式命令行关机行为。
- 保留 Debian 13 行为，不引入 LongQT 的 Debian 12/bookworm 固定值。

### Modem 接口整理

- LongQT 将固定的 `wwan1` 至 `wwan7` 移入隔离 namespace 的意图可以保留，但必须重新实现。
- 只处理运行时实际存在且明确属于辅助 modem 通道的接口。
- 不把主数据接口移出默认 namespace。
- 不依赖 `wwan7` 必须出现。
- 等待超时、接口缺失或单个移动失败不得阻塞启动。
- 需要提供全局启用/禁用配置，并记录实际处理的接口。
- ModemManager 重启只能在明确检测到主 modem 数据接口未初始化时进行。

### Wi-Fi、内核和构建

- 保留 origin 的 Wi-Fi SSID、初始密码和连接模型。
- 不采用 LongQT 将热点加入 `br0` 的设置。
- 不机械复制 LongQT 的硬编码内核下载 URL；内核升级与下载源修复作为独立任务处理。
- 不导入来源或目标硬件不明确的二进制 DTB。
- 不重复移植 origin 已经包含的 MF800 充电支持。
- 不加入 tag 自动发布或 GitHub Release 创建逻辑。

## Testing Decisions

- 以“生成后的 rootfs 配置和外部可观察行为”为主要测试 seam，不为每个 shell 函数建立脆弱的实现细节测试。
- 对新增或修改的 shell 脚本执行语法检查。
- 对 systemd unit 执行静态依赖和命令路径核对；有兼容 Linux 环境时使用 systemd 的 unit 校验工具。
- 对 DHCP 配置验证以下外部结果：唯一租约为 `172.30.255.2/30`，不包含 router option，不包含 DNS option。
- 对 SSH 配置验证 USB 地址允许 root 密码登录，而其他本地地址不允许相同策略。
- 对 UMS 创建逻辑使用临时文件验证：新镜像为 exFAT、卷标正确、容量正确；再次运行不会改变已有镜像内容。
- 对 modem 整理逻辑使用模拟接口清单验证：缺失接口不会失败、主接口不会被移动、禁用配置不产生操作。
- 对首次启动服务验证幂等性：首次执行完成初始化，后续执行不覆盖已生成身份或用户数据。
- 不在本任务中进行真实设备刷写。硬件验收作为实现完成后的明确手工检查清单。

## Acceptance Criteria

1. 插入 USB 后，主机同时看到 RNDIS、ACM 串口和 exFAT UMS。
2. ACM 串口自动进入 root shell，不要求认证。
3. 主机自动获得 `172.30.255.2/30`，开发板可通过 `172.30.255.1` 访问。
4. USB DHCP 不改变主机默认路由，也不设置主机 DNS。
5. `ssh root@172.30.255.1` 使用密码 `1` 可以登录。
6. 空密码 root SSH 登录失败。
7. Wi-Fi 和 LTE 地址不允许使用 USB 专用的 root 密码登录策略。
8. UMS 首次创建后是 100MB、可写、卷标为 `OPENSTICK` 的 exFAT 文件系统。
9. 已存在 UMS 镜像在服务重启或升级后保持字节内容不变。
10. 系统不存在 DNSProxy 服务，不存在新增的 DNS upstream 或 DNS 重定向。
11. 系统不新增 `br0`、NAT、NAT66、VLAN 或转发规则。
12. 每个克隆设备首次启动后拥有独立 machine-id 和 SSH host key。
13. rootfs 扩容和首次启动初始化可以安全重复检查，不破坏已经完成的状态。
14. modem 整理功能可以禁用，且接口缺失时不阻塞启动。
15. origin 的 Wi-Fi 初始接入能力和 MF800 充电支持保持不回归。

## Out of Scope

- AdGuard DNSProxy、DoH、DoQ、DNS fallback、DNS 缓存和 DNS rate limit。
- 自定义 dnsmasq DNS 配置或任何 DNS upstream。
- `br0`、USB/Wi-Fi bridge、VLAN-aware bridge。
- IPv4 NAT、IPv6 NAT66、IP forwarding 和 DNS 强制重定向。
- 将开发板作为 Wi-Fi/LTE 路由器。
- LongQT 的固定 SSID `4G-UFI-XX` 和密码 `1234567890`。
- LongQT 的 `192.168.100.0/24` 和 `dead:beef::/64` 网络。
- ECM、NCM 和 USB 网络自动桥接。
- 自动下载最新 DNSProxy 二进制。
- LongQT 的 Debian bookworm 固定值。
- 未经独立验证的内核 URL、内核升级和二进制 DTB。
- journald 容量策略、zram、shell alias 和普通用户管理重写。
- tag 自动构建、自动创建 GitHub Release。
- 真实设备刷写和硬件兼容性认证。

## Further Notes

- `baiyunquan` 与 `chenge0428` remote 已移除；本任务只使用 `origin` 和 `longqt-sea`。
- 无认证 USB ACM root shell、初始密码 `1`、初始 Wi-Fi 凭据均为开发板易用性决策，需要在面向用户的文档中明确披露。
- `172.30.255.0/30` 仍可能与极少数 VPN 或容器网络冲突，因此地址必须保持集中、可配置。
- 若后续希望通过 USB 为开发板共享主机互联网，应作为独立功能设计，不通过恢复 LongQT 的整个路由器栈实现。
