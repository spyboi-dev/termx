#!/bin/bash
# Runs INSIDE the arm64 Debian chroot (under qemu-aarch64-static).
# Configures the MINIMAL Debian trixie rootfs for TermX: systemd booting to
# multi-user.target, a serial getty with autologin on ttyS0 (the console the
# Kernarium runtime mirrors to the terminal view), user "termx" with
# passwordless sudo, DHCP networking via systemd-networkd, and nothing more
# than the essentials: working apt, curl/wget, nano, openssh-client.
# Users apt-install what they need after boot (python3, git, nodejs, ...).
# No Docker, no python, no node, no git, no build tools bundled.
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8
# Config files must be world-readable (644): on 2026-11-23 the image
# shipped /etc/resolv.conf and /etc/systemd/network/10-eth0.network at
# 660, so systemd-networkd could not read the .network file (eth0 stayed
# unmanaged, no DHCP, no IPv4, no route) and the termx user could not
# read resolv.conf (DNS failed for everyone but root). The chroot had a
# restrictive umask; force 022 here and chmod the files explicitly below.
umask 022

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
# systemd-resolved is a separate package in trixie: without it the
# "systemctl enable systemd-resolved.service" step fails and set -e
# kills the configure (the full-image build died exactly there once,
# after the full package install had already succeeded).
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
      iproute2 iputils-ping curl wget nano less \
      openssh-client tar gzip xz-utils file \
      locales tzdata kmod bash-completion ncurses-base \
      systemd-timesyncd \
      iptables; then
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

echo "== user termx (autologin on the console, passwordless sudo)"
useradd -m -s /bin/bash -G sudo termx || true
echo 'termx:termx' | chpasswd
mkdir -p /etc/sudoers.d
echo 'termx ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/termx
chmod 440 /etc/sudoers.d/termx
passwd -l root || true

echo "== hostname"
echo 'iphone' > /etc/hostname
cat > /etc/hosts <<'EOF'
127.0.0.1 localhost
127.0.1.1 iphone
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
ExecStart=-/sbin/agetty --autologin termx --noclear %I $TERM
EOF
# Belt and braces: the login shell exports the same TERM.
echo 'export TERM=xterm-256color' >> /home/termx/.bashrc
# Prompt shows the real user and host: termx@iphone normally,
# root@iphone after sudo su (bash turns \$ into # for root).
# Appended last in .bashrc so it wins over the default PS1 assignment,
# and also in /etc/bash.bashrc as a fallback.
echo "PS1='\\u@\\h:\\w\\\$ '" >> /home/termx/.bashrc
echo "PS1='\\u@\\h:\\w\\\$ '" >> /etc/bash.bashrc
# PATH: pip --user installs scripts to ~/.local/bin; put it on PATH by
# default so e.g. `igtools` works after `pip install --user`.
# Guarded so sourcing .bashrc twice does not keep prepending it.
echo '# TermX: pip --user installs scripts to ~/.local/bin; put it on PATH.' >> /home/termx/.bashrc
echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' >> /home/termx/.bashrc
echo '# TermX: pip --user installs scripts to ~/.local/bin; put it on PATH.' >> /etc/bash.bashrc
echo 'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac' >> /etc/bash.bashrc
# Terminal width: the terminal shows 48 columns (14 pt font on this
# iPhone), but the guest lays out for 80 by default, so long lines are
# cut at the right edge (fastfetch was the visible case). Set the tty
# width at login so programs wrap at the visible edge. Guarded to a
# real terminal; COLUMNS is the fallback for programs that read the
# variable instead of the winsize. Appended last, after PS1 and PATH.
echo '# TermX: the terminal shows 48 columns; set the tty width at login so programs wrap at the visible edge.' >> /home/termx/.bashrc
echo 'if [ -t 0 ]; then stty cols 48 2>/dev/null; export COLUMNS=48; fi' >> /home/termx/.bashrc
echo '# TermX: the terminal shows 48 columns; set the tty width at login so programs wrap at the visible edge.' >> /etc/bash.bashrc
echo 'if [ -t 0 ]; then stty cols 48 2>/dev/null; export COLUMNS=48; fi' >> /etc/bash.bashrc

echo "== networking: DHCP on eth0 via systemd-networkd"
mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-eth0.network <<'EOF'
[Match]
Name=eth0
[Network]
DHCP=yes
EOF
systemctl enable systemd-networkd.service systemd-resolved.service
# DNS: do not use the systemd-resolved stub. The stub resolv.conf broke
# on device ("Temporary failure resolving 'deb.debian.org'") because the
# stub has no listener when the guest has no other DNS configured.
# Point the guest straight at the runtime's SLiRP nameserver (10.0.2.3).
# resolved stays enabled as a fallback; the static file wins for glibc.
rm -f /etc/resolv.conf
cat > /etc/resolv.conf <<'EOF'
# TermX: SLiRP DNS on the Kernarium user network (10.0.2.3).
nameserver 10.0.2.3
EOF

echo "== console: hide kernel suspend/resume chatter"
mkdir -p /etc/sysctl.d
cat > /etc/sysctl.d/99-termx.conf <<'EOF'
# TermX: keep kernel power-management (suspend/resume) chatter off the
# console. Boot messages print before systemd-sysctl applies this, so
# they still show; later suspend/resume lines are hidden.
kernel.printk = 3 4 1 3
EOF

echo "== minimal fstab (root is mounted by the boot initrd; systemd mounts the API filesystems)"
cat > /etc/fstab <<'EOF'
# termx: root comes from the Kernarium boot ramdisk; nothing else to mount.
tmpfs /tmp tmpfs defaults,nosuid,nodev 0 0
EOF

echo "== motd"
cat > /etc/motd <<'EOF'
TermX — minimal Debian trixie on a real Linux kernel, inside iOS.
You are user "termx" (passwordless sudo). apt works: try "sudo apt update".
Nothing else is bundled: install what you need, e.g. "sudo apt install python3 git nodejs".
EOF

echo "== pip: allow system-wide installs like TermX (PEP 668 off)"
# Debian trixie ships python3 with EXTERNALLY-MANAGED, so `pip3 install`
# refuses system-wide installs. This guest is a Termux-style single-user
# environment: pip installs are allowed by default. Note the marker file
# itself is not in this image (python3 is not bundled); it arrives with
# the python3 package when the user apt-installs it, so the fix is a
# pip config default, not deleting a file that is not here.
cat > /etc/pip.conf <<'EOF'
# TermX: Debian trixie blocks system-wide pip installs with PEP 668
# ("externally-managed-environment"). This guest is a Termux-style
# single-user environment, so pip installs are allowed by default and
# `pip3 install <pkg>` just works, like Termux. The venv/pipx route is
# still available for anyone who wants isolation.
[global]
break-system-packages = true
EOF

echo "== fastfetch: real hardware, not the virtual machine"
# The guest kernel does not know what phone it runs on, so fastfetch
# reports CPU "Unknown", Host "Virtual Machine" and a Kernarium virtual
# GPU. The app writes the real device into ~/.config/termx/host, cpu
# and gpu at boot (it detects the model via sysctl hw.model), and
# fastfetch reads those files here with "command" modules — so the
# values are automatic per device, never hardcoded. If the files are
# absent (older app build), the value falls back to "Unknown" instead
# of a wrong device. Everything else (OS, kernel, memory, disk, ...)
# stays auto-detected. The terminal is 48 columns wide, so line
# wrapping is on (fastfetch defaults it off) and long lines wrap at
# the edge instead of running off the right. The default Debian logo
# and module set are kept.
mkdir -p /home/termx/.config/fastfetch
cat > /home/termx/.config/fastfetch/config.jsonc <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.json",
  // TermX: the guest kernel does not know what phone it runs on, so
  // fastfetch reports CPU "Unknown", Host "Virtual Machine" and a
  // Kernarium virtual GPU. The app writes the real device into
  // ~/.config/termx/host, cpu and gpu at boot (it detects the model
  // via sysctl hw.model), and fastfetch reads those files here — so
  // the values are automatic per device, never hardcoded. If the
  // files are absent (older app build), the value falls back to
  // "Unknown" instead of a wrong device. Everything else is
  // auto-detected.
  "display": {
    // The terminal is 48 columns wide (stty cols 48 at login). Wrap
    // long lines at the terminal width instead of letting them run
    // off the right edge.
    "disableLinewrap": false
  },
  "modules": [
    "title",
    "separator",
    "os",
    {
      "type": "command",
      "key": "Host",
      "text": "cat $HOME/.config/termx/host 2>/dev/null || echo Unknown"
    },
    "kernel",
    "uptime",
    "packages",
    "shell",
    "display",
    "terminal",
    {
      "type": "command",
      "key": "CPU",
      "text": "cat $HOME/.config/termx/cpu 2>/dev/null || echo Unknown"
    },
    {
      "type": "command",
      "key": "GPU",
      "text": "cat $HOME/.config/termx/gpu 2>/dev/null || echo Unknown"
    },
    "memory",
    "swap",
    "disk",
    "localip",
    "locale",
    "break",
    "colors"
  ]
}
EOF
chown -R termx:termx /home/termx/.config
chmod 644 /home/termx/.config/fastfetch/config.jsonc

echo "== config file permissions (644; sudoers stays 440)"
# Belt and braces for the umask above: every plain config file this
# script creates must be world-readable, or the service / user that
# needs it cannot read it (see the 2026-11-23 660 breakage above).
chmod 644 /etc/hosts /etc/timezone \
  /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf \
  /etc/systemd/network/10-eth0.network /etc/resolv.conf \
  /etc/sysctl.d/99-termx.conf /etc/fstab /etc/motd \
  /etc/apt/sources.list /etc/hostname /etc/pip.conf \
  /home/termx/.config/fastfetch/config.jsonc

echo "== verify the units parse"
systemd-analyze verify default.target multi-user.target serial-getty@ttyS0.service systemd-networkd.service systemd-resolved.service || echo "systemd-analyze verify reported issues (see above)"

echo "== versions"
/usr/lib/systemd/systemd --version | head -1  # no /usr/bin/systemd in Debian
apt-get --version | head -1
bash --version | head -1

echo "== cleanup"
apt-get clean
rm -rf /var/cache/apt/archives/*.deb
rm -rf /debootstrap
rm -f /.termx-second-stage-done
rm -f /usr/bin/qemu-aarch64-static
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
echo "CONFIGURE DONE"
