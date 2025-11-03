#!/usr/bin/env bash
set -euxo pipefail

ROLE="${1:-server}"
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------
# Base packages
# ---------------------------------------------------------------------
apt-get update
apt-get install -y \
  build-essential git curl pkg-config cmake \
  software-properties-common ca-certificates \
  linux-tools-common linux-tools-generic \
  ethtool net-tools iperf3 numactl bc flex bison libelf-dev libssl-dev \
  dwarves zstd

# ---------------------------------------------------------------------
# Install a mainline 6.17-rc2 kernel for io_uring RECV_ZC
# ---------------------------------------------------------------------
cd /tmp
KVER="6.17-rc2"

if [ ! -d "linux-$KVER" ]; then
  echo "[*] Downloading Linux $KVER ..."
  wget -q https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$KVER.tar.xz
  tar -xf linux-$KVER.tar.xz
fi

cd linux-$KVER
echo "[*] Building kernel $KVER (this can take ~10–15 min) ..."
make defconfig

# Enable io_uring + network + Mellanox NICs
scripts/config --enable CONFIG_IO_URING
scripts/config --enable CONFIG_NET
scripts/config --enable CONFIG_INET
scripts/config --enable CONFIG_TCP_ZEROCOPY_RECEIVE
scripts/config --enable CONFIG_MELLANOX_CORE
scripts/config --enable CONFIG_MLX5_CORE
scripts/config --enable CONFIG_MLX5_CORE_EN
scripts/config --enable CONFIG_BPF
scripts/config --enable CONFIG_BPF_SYSCALL
scripts/config --enable CONFIG_EXPERIMENTAL

# Build and install
make -j"$(nproc)"
make modules_install
make install

update-initramfs -c -k "$KVER" || true
update-grub || true
grub-set-default 0 || true

echo "[*] Installed new kernel $KVER"

# ---------------------------------------------------------------------
# Sysctl / system tuning
# ---------------------------------------------------------------------
cat >/etc/sysctl.d/99-ringbling.conf <<'EOF'
vm.max_map_count = 1048576
net.core.rmem_max = 536870912
net.core.wmem_max = 536870912
net.ipv4.tcp_rmem = 4096 87380 536870912
net.ipv4.tcp_wmem = 4096 65536 536870912
EOF
sysctl --system

cat >/etc/security/limits.d/99-memlock.conf <<'EOF'
* soft memlock unlimited
* hard memlock unlimited
EOF

if command -v cpupower >/dev/null 2>&1; then
  cpupower frequency-set -g performance || true
fi

# ---------------------------------------------------------------------
# Configure experiment network
# ---------------------------------------------------------------------
EXP_IFACE="$(ip -o -4 addr show | awk '/10\.10\.1\./{print $2; exit}')"
if [ -n "${EXP_IFACE:-}" ]; then
  ip link set "$EXP_IFACE" mtu 9000 || true
  ethtool -K "$EXP_IFACE" gro off lro off tso off gso off || true
fi

echo "ROLE=$ROLE"
uname -r || true
ip -o -4 addr show

# ---------------------------------------------------------------------
# Post-reboot automation script
# ---------------------------------------------------------------------
cat >/root/post_reboot.sh <<'EOS'
#!/usr/bin/env bash
set -euxo pipefail
echo "[*] Running post-reboot setup (Rust + repo build)..."

# 1. Install Rust toolchain
if ! command -v cargo >/dev/null 2>&1; then
  curl -sSf https://sh.rustup.rs | sh -s -- -y
  source "$HOME/.cargo/env"
fi

# 2. Verify kernel version
uname -r

# 3. Clone and build the CSCI2690-project repo
cd /users/ron1tk || cd /root
if [ ! -d CSCI2690-project ]; then
  git clone https://github.com/ke1thw/CSCI2690-project.git
fi
cd CSCI2690-project/io_uring_echo_test/io_uring_echo_test
. "$HOME/.cargo/env"
cargo build --release

echo "[*] Build complete. Binaries available at:"
ls -lh ./target/release/
EOS

chmod +x /root/post_reboot.sh

# ---------------------------------------------------------------------
# Run post_reboot.sh automatically on next boot
# ---------------------------------------------------------------------
cat >/etc/rc.local <<'EOF'
#!/usr/bin/env bash
bash /root/post_reboot.sh > /root/post_reboot.log 2>&1
exit 0
EOF

chmod +x /etc/rc.local

# ---------------------------------------------------------------------
# Reboot into new kernel
# ---------------------------------------------------------------------
echo "[*] Rebooting into kernel $KVER ..."
sleep 3
reboot
