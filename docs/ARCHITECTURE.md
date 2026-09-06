# 架构与后续开发

程序只实现 v0.20.5 核心协议。服务器地址、端口及密钥来自运行参数；
OpenWrt 的 procd 脚本从设备 UCI 配置读取相同参数。

| 模块 | 职责 |
| --- | --- |
| src/main.zig | 状态上报、任务接收、固定工作线程和结果回报 |
| src/config.zig | 必填 endpoint、密钥及资源上限参数 |
| src/proto.zig | 旧版 Protobuf 编解码与回执验证 |
| src/h2.zig / src/hpack.zig | HTTP/2、gRPC framing、HPACK 与发送流控 |
| src/socket_io.zig | 非阻塞 TCP 与单调时钟 deadline |
| src/bounded_queue.zig | 有界队列，防止无限创建线程和积压 |
| src/monitor.zig | Linux 主机和状态采集 |
| src/mounts.zig / src/release_info.zig | 磁盘筛选/去重、简短发行版名称 |
| src/icmp_linux.zig / src/icmp_packet.zig | ICMP socket、校验及并发回包匹配 |
| protocol/nezha-v0.20.5.proto | 固定协议快照 |

状态上报拥有独立连接和线程。主线程读取任务流并快速入队；ICMP worker 执行探测，
结果回报 worker 使用各自的连接发送结果。三条路径分别承受网络延迟和任务负载。

每个连接同时只有一个活动 RPC，但可复用连接进行多个一元调用。TaskStream 保持
独立连接。固定工作线程使用 256 KiB 栈上限；32 个 ICMP worker、2 个结果 worker
时，进程共有 36 个线程。虚拟栈地址预留与实际 RSS 需要分别理解。

服务器、端口和密钥缺失时立即返回配置错误。自动化测试使用明确的本机回环地址或
QEMU 保留网络；手动远端探针要求显式设置 NEZHA_TEST_HOST、NEZHA_TEST_PORT、
NEZHA_TEST_SECRET。探针发送构造指标，仅用于指定的测试节点。

可以优先继续完善：DNS 全流程 deadline、网卡/磁盘白名单、长期故障注入、
更多目标平台验证。增加新 RPC 前先确认旧版协议方向及字段编号，新增任务应继续遵守
有界并发和结果所有权约定。
