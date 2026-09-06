# Repeatable validation

Use Zig 0.15.2. From the zig-agent directory:

    zig build test
    zig build probe
    python -m pip install -r tests/requirements.txt
    python tests/protocol_integration.py --output test-results/protocol-integration.json

The portable unit tests cover Protobuf receipts, HPACK error-path ownership,
gRPC framing, send windows, deadlines, configuration limits, a bounded queue
with eight consumer threads, and concurrent ICMP packet matching.
They also cover concise distribution names and a synthetic OpenWrt overlay/data mount layout,
including data partitions, overlay/bind mount deduplication and escaped paths.
The Protobuf golden bytes are generated independently with Google Protobuf
from protocol/nezha-v0.20.5.proto:

    python tests/generate_proto_vectors.py
    zig fmt src/testdata
The independent hyper-h2 peer checks cumulative traffic above 64 KiB, a
32-byte stream window, rejection, malformed/truncated responses, missing
trailers, stream reset, handshake timeout, RPC timeout and partial-frame stalls.
All native integration connections are to 127.0.0.1.

For the actual Linux implementation, build the ARM64 executable:

    zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a53 -Doptimize=ReleaseSmall --prefix zig-out/aarch64
    python tests/openwrt_integration.py --qemu PATH_TO_QEMU --image PATH_TO_ARM64_VIRT_INITRAMFS

The runner uses a fresh QEMU guest with Cortex-A53, four emulated CPUs and
256 MiB RAM. It installs the current binary and procd script into that guest,
creates a local mock dashboard, and performs:

- Real Linux host/state reports and failure exit codes for rejected receipts.
- procd startup using the main UCI section.
- Bursts of 8, 16 and 32 ICMP tasks at 30-second intervals.
- IPv6 ping sockets and concurrent IPv4 raw sockets to the same target.
- 32 fully timed-out probes while state reports continue.
- Slow result receipts, connection loss/recovery and protocol control tasks.
- Bounded queue overflow with explicit failure reports.

The guest's loopback ICMP behavior and ping_group_range are changed only inside
the disposable virtual machine. No actual router, real dashboard, or user
credential is used. QEMU is started without a visible window and terminated
when the runner finishes. The loopback file server exposes only staged test
artifacts. JSON results and the guest console log are kept in test-results.

The default --period is 30 seconds; changing it is useful for diagnosis but
does not validate the requested 30-second workload. QEMU measurements establish
functional evidence, not IPQ60xx performance or long-term production readiness.

The runner also supports --arch x86_64 with a raw combined OpenWrt disk image
and an x86_64 agent binary. It uses a disposable QEMU disk snapshot.

Real-device testing uses tests/device_local_integration.py with an existing
Bitvise profile. It stages a loopback-only Lua/nixio fixture and the executable
in a unique /tmp directory, runs 61 batches at 30-second intervals, verifies
every result receipt, and cleans up only its own processes/files. The installed
Go agent is not restarted. The optional cross-machine harness in device_integration.py requires a
working SSH reverse forward or a reachable LAN listener. The device-local
harness avoids these dependencies.

tests/compare_resources.py takes simultaneous /proc samples of the installed
Go agent and the live Zig agent. CPU percentages use accumulated process time,
normalized so one fully busy core is 100%. RSS is reported in KiB. PSS is
included only if the running kernel exposes it. The two agents keep their
existing real dashboard workloads; this is not a synthetic workload parity test.

Manual probes in src/probe_main.zig, src/probe_task_main.zig and
src/probe_continuous_main.zig require NEZHA_TEST_HOST, NEZHA_TEST_PORT and
NEZHA_TEST_SECRET. They contain no configured remote endpoint. These probes
use synthetic metrics and may submit a failed task result; use a dedicated
test node. Automated integration tests bind loopback or the reserved QEMU
network and never require real dashboard credentials.

All raw results, device/session metadata and console logs stay in test-results/
and are excluded from Git and public release packaging. Public test history
is summarized in docs/VALIDATION.md.
