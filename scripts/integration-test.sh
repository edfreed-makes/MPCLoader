#!/usr/bin/env bash
# Runs MPCKit's integration tests against a stand-in MPC: a local SSH server that lets root in
# with no password and has the same drive layout as an MPC (system partition, internal
# storage, factory content, removable drives).
#
# It changes the root password, mounts things under /media and starts an SSH server, so it
# only runs inside a throwaway container:
#
#   docker run --rm --privileged -v "$PWD":/src -w /src <image with swift, openssh-server, busybox> \
#       scripts/integration-test.sh
set -euo pipefail

if [ "$(id -u)" != 0 ] || [ ! -f /.dockerenv ]; then
  echo "This script only runs as root inside a disposable container." >&2
  exit 1
fi

BUILD_PATH="${BUILD_PATH:-.build}"
PORT=2222
FAKE=/srv/fake-mpc
SSHD_DIR=/tmp/mpcl-sshd
MODES="${MODES:-gnu busybox password few-sessions}"

# ---- the stand-in MPC's drives --------------------------------------------------------------
rm -rf "$FAKE"; mkdir -p "$FAKE"/{system,internal-sd,content,synths,usb,locked,nvme}
mkdir -p /media/az01-internal /media/az01-internal-sd /media/acvs-content /media/acvs-synths \
         "/media/MY USB" /media/LOCKED /media/ramdisk /nvme

mkdir -p "$FAKE/system/system/etc/overlay" && echo "root::0:0::/root:/bin/sh" > "$FAKE/system/system/etc/overlay/passwd"
mkdir -p "$FAKE/content/Expansions/Factory Kit" && printf 'RIFFfactory' > "$FAKE/content/Expansions/Factory Kit/kick.wav"
echo "locked" > "$FAKE/locked/readme.txt"

mount --bind "$FAKE/system" /media/az01-internal
mount --bind "$FAKE/internal-sd" /media/az01-internal-sd
mount --bind "$FAKE/content" /media/acvs-content
mount --bind "$FAKE/synths" /media/acvs-synths
mount --bind "$FAKE/usb" "/media/MY USB"
mount --bind "$FAKE/nvme" /nvme
mount --bind "$FAKE/locked" /media/LOCKED && mount -o remount,ro,bind /media/LOCKED
mount -t tmpfs tmpfs /media/ramdisk

# A small real drive on its own device, for free-space reporting and the "drive is full" case.
export MPCKIT_IT_SMALL=""
if truncate -s 48M "$FAKE/small.img" && mkfs.ext4 -q -F "$FAKE/small.img" >/dev/null 2>&1 \
   && mkdir -p /media/SMALLDRIVE && mount -o loop "$FAKE/small.img" /media/SMALLDRIVE 2>/dev/null; then
  export MPCKIT_IT_SMALL=/media/SMALLDRIVE
  echo "== small ext4 loop drive mounted at /media/SMALLDRIVE"
else
  echo "== no loop mount available: drive-full test will be skipped"
fi

# Real exFAT and FAT32 drives when the kernel supports them. An MPC formats its drives as exFAT,
# and FAT32 is what many SD cards and USB sticks ship with.
export MPCKIT_IT_FAT=""
if truncate -s 64M "$FAKE/exfat.img" && mkfs.exfat -L EXSTICK "$FAKE/exfat.img" >/dev/null 2>&1 \
   && mkdir -p /media/EXSTICK && mount -o loop "$FAKE/exfat.img" /media/EXSTICK 2>/dev/null; then
  MPCKIT_IT_FAT=/media/EXSTICK
  echo "== exFAT loop drive mounted at /media/EXSTICK"
fi
if truncate -s 48M "$FAKE/fat.img" && mkfs.vfat -n FATSTICK "$FAKE/fat.img" >/dev/null 2>&1 \
   && mkdir -p /media/FATSTICK && mount -o loop,utf8 "$FAKE/fat.img" /media/FATSTICK 2>/dev/null; then
  MPCKIT_IT_FAT="${MPCKIT_IT_FAT:+$MPCKIT_IT_FAT:}/media/FATSTICK"
  echo "== FAT32 loop drive mounted at /media/FATSTICK"
fi
[ -n "$MPCKIT_IT_FAT" ] || echo "== no exFAT or FAT support in this kernel: those tests will be skipped"

echo "AZ01_VERSION=3.10.1.99" > /etc/az01-release

# ---- busybox userlands, as found on embedded Linux --------------------------------------------
rm -rf /bbin; mkdir -p /bbin
for applet in $(busybox --list); do
  ln -sf "$(command -v busybox)" "/bbin/$applet"
done

# ---- SSH server -------------------------------------------------------------------------------
rm -rf "$SSHD_DIR"; mkdir -p "$SSHD_DIR" /run/sshd
ssh-keygen -q -t ed25519 -N '' -f "$SSHD_DIR/host_key"

start_sshd() {  # start_sshd <empty-passwords yes|no> [PATH override] [sessions allowed per connection]
  if [ -f "$SSHD_DIR/pid" ]; then kill "$(cat "$SSHD_DIR/pid")" 2>/dev/null || true; sleep 0.3; fi
  {
    echo "Port $PORT"
    echo "ListenAddress 127.0.0.1"
    echo "HostKey $SSHD_DIR/host_key"
    echo "PidFile $SSHD_DIR/pid"
    echo "PermitRootLogin yes"
    echo "PasswordAuthentication yes"
    echo "PermitEmptyPasswords $1"
    echo "UsePAM no"
    echo "MaxSessions ${3:-20}"
    echo "MaxStartups 50"
    [ -z "${2:-}" ] || echo "SetEnv PATH=$2"
  } > "$SSHD_DIR/sshd_config"
  /usr/sbin/sshd -f "$SSHD_DIR/sshd_config" -E "$SSHD_DIR/log"
  for _ in $(seq 1 50); do [ -f "$SSHD_DIR/pid" ] && break; sleep 0.1; done
}

swift build --build-tests --build-path "$BUILD_PATH" 2>&1 | tail -n 3

export MPCKIT_IT_HOST=127.0.0.1 MPCKIT_IT_PORT=$PORT MPCKIT_IT_USER=root
status=0
for mode in $MODES; do
  unset MPCKIT_IT_PASSWORD
  export MPCKIT_IT_MODE="$mode"
  case "$mode" in
    gnu)
      usermod -s /bin/bash root; passwd -d root >/dev/null; start_sshd yes ;;
    busybox)
      usermod -s /bbin/sh root; passwd -d root >/dev/null; start_sshd yes /bbin ;;
    password)
      usermod -s /bin/bash root
      export MPCKIT_IT_PASSWORD="s3cret pa\$\$'word"
      echo "root:$MPCKIT_IT_PASSWORD" | chpasswd
      start_sshd no ;;
    few-sessions)
      # A server that only allows two sessions on a connection, to check copying adapts to it.
      usermod -s /bin/bash root; passwd -d root >/dev/null; start_sshd yes "" 2 ;;
  esac
  echo "================ mode: $mode ================"
  if ! swift test --skip-build --build-path "$BUILD_PATH" 2>&1 | grep -E "error|failed|Executed|skipped|XCTAssert|Fatal|crash" ; then status=1; fi
  if [ "${PIPESTATUS[0]}" != 0 ]; then status=1; echo "MODE $mode FAILED"; fi
done
kill "$(cat "$SSHD_DIR/pid")" 2>/dev/null || true
exit $status
