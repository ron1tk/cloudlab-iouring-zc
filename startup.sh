#!/usr/bin/env bash
set -euxo pipefail

ROLE="${1:-server}"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  build-essential git curl pkg-config cmake \
  software-properties-common ca-certificates \
  linux-tools-common linux-tools-generic \
  ethtool net-tools iperf3 numactl

# Optional: Rust toolchain (uncomment if you’ll build Rust echo/bench)
# if ! command -v cargo >/dev/null 2>&1; then
#   curl -sSf https://sh.rustup.rs | sh -s -- -y
#   . "$HOME/.cargo/env"
# fi

# liburing (new enough for *_SEND_ZC paths)
cd /tmp
if [ ! -d liburing ]; then
  git clone --depth 1 --branch liburing-2.7 https://github.com/axboe/liburing.git
fi
cd liburing
./configure --prefix=/usr
make -j"$(nproc)"
make install
ldconfig

# Sysctls (valid ones only)
cat >/etc/sysctl.d/99-ringbling.conf <<'EOF'
# Map count for lots of buffers
vm.max_map_count = 1048576
# Network buffers
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
net.ipv4.tcp_rmem = 4096 87380 536870912
net.ipv4.tcp_wmem = 4096 65536 536870912
EOF
sysctl --system

# Allow large pinned memory for all users (applies at login shells)
cat >/etc/security/limits.d/99-memlock.conf <<'EOF'
* soft memlock unlimited
* hard memlock unlimited
EOF

# Set performance governor if available
if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g performance || true
fi

# Find the experiment iface (the one with 10.10.1.x)
EXP_IFACE="$(ip -o -4 addr show | awk '/10\.10\.1\./{print $2; exit}')"
if [ -n "${EXP_IFACE:-}" ]; then
  ip link set "$EXP_IFACE" mtu 9000 || true
  ethtool -K "$EXP_IFACE" gro off lro off tso off gso off || true
fi

# Print quick info
echo "ROLE=$ROLE"
uname -r
ip -o -4 addr show

# No reboot needed on Ubuntu 24 (already 6.8+)
