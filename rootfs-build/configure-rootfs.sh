#!/bin/bash
# Runs INSIDE the arm64 Debian chroot (under qemu-aarch64-static).
# Configures the minimal Debian trixie rootfs for TermX: systemd booting to
# multi-user.target, a serial getty with autologin on ttyS0 (the console the
# Kernarium runtime mirrors to the terminal view), user "termux" with
# passwordless sudo, DHCP networking via systemd-networkd, and the tool set
# a Termux user expects (apt, python3, git, curl, ...).
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

# The VM egress proxy (hatch-egress-proxy) resolves to an IPv6 address that
# works and an IPv4 pool that is dead from inside this chroot: apt under
# qemu picks IPv4 (Connection failed [IP: 198.18.19.77 3128]) while host
# tools pick IPv6 and succeed. Pin the hostname to its IPv6 address so apt
# always uses the working backend. The hostname section below overwrites
# /etc/hosts with the clean guest entries, so the pin never ships in the
# image. The IPv6 address is the cell gateway address, stable across boots.
PROXY6=$(getent ahosts hatch-egress-proxy 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
if [ -z "$PROXY6" ]; then
  PROXY6=$(awk '$1 == "nameserver" && $2 ~ /:/ {print $2; exit}' /etc/resolv.conf)
fi
if [ -n "$PROXY6" ] && ! grep -q hatch-egress-proxy /etc/hosts; then
  echo "$PROXY6 hatch-egress-proxy" >> /etc/hosts
  echo "pinned hatch-egress-proxy to $PROXY6 in /etc/hosts"
fi

echo "== apt sources"
cat > /etc/apt/sources.list <<'EOF'
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF

# The VM's egress proxy fails in bursts (Connection failed [IP:
# 198.18.3.1 3128]); a single apt failure must not kill the build.
# docker-cli is only a Recommends of docker.io, skipped by
# --no-install-recommends; without it dockerd/containerd/runc are
# present but the "docker" command the user types does not exist
# (resume 6 died on "docker: command not found").
# systemd-resolved is a separate package in trixie: without it the
# "systemctl enable systemd-resolved.service" step fails and set -e
# kills the configure (resume 5 died exactly there, after the full
# 190-package install had already succeeded).
# Retry update until no index fetch fails, and install up to 3 times.
apt_update_retry() {
  local i out
  for i in 1 2 3 4 5; do
    echo "apt-get update (attempt $i/5)"
    out=$(apt-get update -o Acquire::Queue-Mode=access 2>&1) || true
    echo "$out" | grep "Failed to fetch" || true
    echo "$out" | tail -2
    # Only the main trixie repo matters for this build: every package
    # installed here comes from main. trixie-security / trixie-updates
    # failing through the VM proxy is a warning, not a build failure
    # (the guest re-runs apt update on its own network later).
    if ! echo "$out" | grep -q "Failed to fetch http://deb.debian.org/debian/dists/trixie/InRelease"; then return 0; fi
    echo "apt-get update failed to fetch the main trixie index, retrying in 15s..."
    sleep 15
  done
  echo "apt-get update still failing after 5 attempts" >&2
  return 1
}

apt_install_retry() {
  local i
  for i in 1 2 3; do
    echo "apt-get install (attempt $i/3)"
    if apt-get install -o Acquire::Queue-Mode=access -y --no-install-recommends \
      systemd systemd-sysv systemd-resolved udev dbus \
      bash coreutils util-linux mount procps psmisc \
      apt dpkg ca-certificates debian-archive-keyring gnupg \
      sudo passwd adduser \
      iproute2 iputils-ping curl wget git vim nano less \
      python3 python3-pip htop openssh-client unzip zip tar gzip xz-utils file \
      locales tzdata kmod bash-completion ncurses-base \
      systemd-timesyncd \
      nodejs build-essential docker.io docker-cli iptables; then
      return 0
    fi
    echo "apt-get install failed (attempt $i/3), retrying in 15s..."
    sleep 15
  done
  echo "apt-get install still failing after 3 attempts" >&2
  return 1
}

echo "== apt update"
apt_update_retry

echo "== install tools"
apt_install_retry

echo "== user termux (autologin on the console, passwordless sudo)"
useradd -m -s /bin/bash -G sudo termux || true
echo 'termux:termux' | chpasswd
mkdir -p /etc/sudoers.d
echo 'termux ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/termux
chmod 440 /etc/sudoers.d/termux
passwd -l root || true

echo "== hostname"
echo 'termx' > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 termx
::1 localhost ip6-localhost ip6-loopback
EOF

echo "== timezone + locale"
ln -sf /usr/share/zoneinfo/Asia/Kolkata /etc/localtime
echo 'Asia/Kolkata' > /etc/timezone
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8

echo "== boot target: text multi-user, no GUI"
systemctl set-default multi-user.target

echo "== serial getty on ttyS0 with autologin"
systemctl enable serial-getty@ttyS0.service
mkdir -p /etc/systemd/system/serial-getty@ttyS0.service.d
cat > /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf <<'EOF'
[Service]
# The terminal speaks xterm-256color (what the TermX view emulates).
Environment=TERM=xterm-256color
ExecStart=
ExecStart=-/sbin/agetty --autologin termux --noclear %I $TERM
EOF
# Belt and braces: the login shell exports the same TERM.
echo 'export TERM=xterm-256color' >> /home/termux/.bashrc

echo "== networking: DHCP on eth0 via systemd-networkd"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0
[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd.service systemd-resolved.service
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

echo "== minimal fstab (root is mounted by the boot initrd; systemd mounts the API filesystems)"
cat > /etc/fstab <<'EOF'
# termx: root comes from the Kernarium boot ramdisk; nothing else to mount.
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

echo "== motd"
cat > /etc/motd <<'EOF'
TermX — Debian trixie on a real Linux kernel, inside iOS.
You are user "termux" (passwordless sudo). apt works: try "sudo apt update".
Docker, Node.js and build tools are pre-installed: try "sudo docker run hello-world".
EOF

echo "== verify the units parse"
systemd-analyze verify default.target multi-user.target serial-getty@ttyS0.service systemd-networkd.service systemd-resolved.service || echo "systemd-analyze verify reported issues (see above)"

echo "== versions"
/usr/lib/systemd/systemd --version | head -1  # no /usr/bin/systemd in Debian
apt-get --version | head -1
python3 --version
git --version
node --version
docker --version
bash --version | head -1

echo "== cleanup"
apt-get clean
rm -rf /var/cache/apt/archives/*.deb
rm -rf /debootstrap
rm -f /usr/bin/qemu-aarch64-static
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
echo "CONFIGURE DONE"
