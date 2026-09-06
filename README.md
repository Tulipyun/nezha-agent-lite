# nezha-agent-lite

使用 Zig 实现的 Linux / OpenWrt 精简哪吒 Agent，兼容 **Nezha Agent v0.20.5 核心协议**。
优先支持 ARM64 Cortex-A53 / IPQ60xx，同时提供 Linux x86_64 静态二进制。
这是独立项目；当前上游 v2 协议和完整 Go Agent 功能不在本版本范围内。

**下载与启动**

从 [Releases](https://github.com/Tulipyun/nezha-agent-lite/releases) 下载对应架构的程序，
赋予执行权限后，通过启动参数指定服务器、端口和客户端密钥：

    chmod +x nezha-agent-lite
    ./nezha-agent-lite --server 'YOUR_HOST:YOUR_PORT' --password 'YOUR_CLIENT_SECRET'

把占位值替换成实际配置。简写参数是 -s 和 -p；IPv6 使用 [IPv6地址]:端口。
服务器、端口和密钥均为必填项，正式程序没有预置的远端连接地址。
同一架构的二进制可通过参数连接不同的兼容面板，无需重新编译。

本构建仅支持明文 HTTP/2 gRPC（h2c prior knowledge）。部署时应使用可信网络、
VPN 或受保护的传输链路；本版本不包含 TLS。

**实现范围**

- 主机信息与 CPU、内存、Swap、磁盘、网络、负载、运行时间、连接数、进程数。
- 发行版名称与架构分开上报；磁盘按旧版 Go 默认规则汇总挂载设备并去重。
- ReportSystemInfo、ReportSystemState、RequestTask、ReportTask。
- IPv4 / IPv6 ICMP，ping socket 与 raw socket，按来源、序号和任务 nonce 匹配回包。
- 固定工作线程、有界任务/结果队列、连接复用、发送流控、超时及重连。
- 保留 Keepalive / ReportHostInfo 控制任务；未支持的任务返回明确失败。

当前不实现 TLS、uTLS、HTTP/3、QUIC、TCP/HTTP 探测、远程命令、终端、NAT、
文件管理、GPU 或温度采集。

**运行参数**

| 参数 | 默认值 | 范围 / 含义 |
| --- | --- | --- |
| -s / --server | 必填 | 主机名或 IP 与端口，格式 host:port 或 [IPv6]:port |
| -p / --password | 必填 | 面板为该节点分配的客户端密钥 |
| --workers | 8 | 1–64 个 ICMP worker |
| --report-workers | 2 | 1–8 个结果回报 worker |
| --queue-capacity | 128 | 1–1024 个待执行任务；结果队列容量 max(128, 2×此值) |
| --task-max-age | 30 | 1–300 秒，包含排队和 ICMP 执行时间 |
| --report-delay | 1 | 1–30 秒，独立状态上报周期 |
| --rpc-timeout | 5 | 1–60 秒，TCP/握手与单次 RPC 的超时预算 |
| --debug | 关闭 | 输出逐项任务确认；必要错误及周期汇总始终记录 |
| --once | 关闭 | 只上报一次主机与状态；失败返回非零退出码 |
| -h / --help | — | 显示帮助 |

每个 ICMP 任务最多 5 次探测、最多 20 秒。面板可每 30 秒下发一批任务；
Agent 按收到的任务执行，不生成重复调度。状态上报与任务执行互相独立。
对每批 32 个、可能全部超时的目标，建议先按 --workers 32 验证实际容量。
满队列、过期任务和未确认结果都会记录；队列用于吸收突发，持续吞吐量需按设备测量。

OpenWrt 使用 [procd 与 UCI 配置](openwrt/README.md)。示例配置的服务器和密钥为空，
必须在设备上填写，程序与服务脚本不会使用隐藏默认地址。

**编译**

固定使用 Zig 0.15.2；当前尚未迁移到 Zig 0.16 的 I/O API。

    zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a53 -Doptimize=ReleaseSmall --prefix zig-out/aarch64
    zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSmall --prefix zig-out/x86_64

输出是 stripped、静态链接的 ELF64，位于各自前缀的 bin/nezha-agent-lite。
其他 Linux CPU/架构可按 Zig 的 -Dtarget / -Dcpu 参数自行构建，需完成对应平台验证。

**测试与开发**

    zig build test
    zig build probe
    python -m pip install -r tests/requirements.txt
    python tests/protocol_integration.py --output test-results/protocol-integration.json

CI 在 Linux 上运行单元测试、本机 HTTP/2 互操作测试及两种架构构建，不访问真实面板。
设备/QEMU 测试和手动探针说明见 [tests/README.md](tests/README.md)。
模块说明见 [架构与开发说明](docs/ARCHITECTURE.md)，测试边界与历史测量见
[验证记录](docs/VALIDATION.md)。

开发阶段在一台四核 ARMv8 OpenWrt 设备上、180 秒真实运行窗口中，Go / Zig 的平均 RSS
分别约 14.08 / 1.04 MiB，平均单核 CPU 占用约 1.69% / 0.49%。
该结果对应精简功能、32 个 Zig worker 和各自当时的任务负载，其他环境应重新测量。

**已知边界**

- DNS 解析仍使用平台解析器的超时；网络读写 deadline 不保证及时中断 DNS。
- 回执丢失后的重试可能重复提交结果；旧版协议没有严格的 exactly-once 机制。
- 连接数采集有 procfs 读取上限；网卡/挂载点白名单及更长时间验证可继续完善。
- 配置较长的状态上报间隔时，需要核对面板的在线判定。

**许可证**

[Apache-2.0](LICENSE)。上游协议来源及静态链接组件的许可说明见 [NOTICE](NOTICE)
和 [licenses/](licenses/)。
