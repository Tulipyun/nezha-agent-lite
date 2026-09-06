# OpenWrt 部署

选择与设备架构相符的静态二进制。IPQ60xx 优先使用 aarch64 / Cortex-A53 构建；
部署前先检查 uname -m。服务器必须兼容 v0.20.5 明文 gRPC。

1. 将程序安装为 /usr/bin/nezha-agent-lite。
2. 将 nezha-agent.init 安装为 /etc/init.d/nezha-agent。
3. 将 config.example 复制为 /etc/config/nezha-agent，并填写 main 节中的服务器和密钥。

配置示例（必须替换占位值）：

    uci set nezha-agent.main.server='YOUR_HOST:YOUR_PORT'
    uci set nezha-agent.main.secret='YOUR_CLIENT_SECRET'
    uci set nezha-agent.main.workers='8'
    uci set nezha-agent.main.report_workers='2'
    uci set nezha-agent.main.queue_capacity='128'
    uci set nezha-agent.main.report_delay='1'
    uci commit nezha-agent
    chmod 600 /etc/config/nezha-agent
    chmod 755 /usr/bin/nezha-agent-lite /etc/init.d/nezha-agent
    /etc/init.d/nezha-agent enable
    /etc/init.d/nezha-agent start
    logread -e nezha-agent

服务器使用 host:port 或 [IPv6]:port，地址、端口和密钥都没有内置的远端默认值。
启动脚本读取 UCI 后，把配置作为 -s、-p 和其他运行参数传给同一份二进制。
不要把本机填写后的配置、SSH 配置、私钥或完整运行日志提交到仓库。

workers 范围 1–64，默认 8。对每 30 秒一批 32 个可能超时的目标，可设置 workers=32
后验证容量。状态上报周期独立于面板的 ICMP 调度；debug=1 可输出每个结果的确认日志。
每 30 秒汇总包含队列峰值、完成/拒绝数量、回报错误和未确认结果数。

ICMP 优先使用 Linux ping socket；权限不允许时回退到 raw socket。
服务通常以 root 运行。数据回报失败或任务排队过久时有明确日志，详细限制见主 README。
