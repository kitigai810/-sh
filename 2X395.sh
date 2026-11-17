#!/bin/bash
set -euo pipefail

# ThinkPad X395 / Tahoe remote preparation helper.
# Run this on Tahoe locally from an administrator account.
# It enables SSH over the current Wi-Fi network and saves basic diagnostics.

usage() {
  cat <<'EOF'
使い方:
  sudo bash enable-x395-remote.sh
  sudo bash enable-x395-remote.sh --screen-sharing

デフォルトではSSHだけを有効にします。
--screen-sharing を付けた場合だけ画面共有も有効にします。
EOF
}

SCREEN_SHARING=0
case "${1:-}" in
  "") ;;
  --screen-sharing) SCREEN_SHARING=1 ;;
  -h|--help) usage; exit 0 ;;
  *) echo "不明なオプション: $1" >&2; usage >&2; exit 2 ;;
esac

if [[ "$(id -u)" -ne 0 ]]; then
  echo "このスクリプトは管理者権限が必要です。" >&2
  echo "例: sudo bash $0" >&2
  exit 1
fi

CONSOLE_USER="$(stat -f '%Su' /dev/console 2>/dev/null || true)"
if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" ]]; then
  echo "現在ログイン中の通常ユーザーを特定できません。" >&2
  echo "Tahoeへ通常ユーザーでログインしてから実行してください。" >&2
  exit 1
fi

# Find the BSD interface corresponding to the Wi-Fi hardware.
WIFI_IF="$(networksetup -listallhardwareports 2>/dev/null | awk '
  /^Hardware Port: (Wi-Fi|AirPort)$/ { want=1; next }
  want && /^Device: / { print $2; exit }
  /^Hardware Port:/ { want=0 }
')"

if [[ -z "$WIFI_IF" ]]; then
  echo "Wi-Fiインターフェースを特定できませんでした。" >&2
  echo "networksetup -listallhardwareports の結果を確認してください。" >&2
  exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
USER_HOME="$(dscl . -read "/Users/$CONSOLE_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
USER_HOME="${USER_HOME:-/Users/$CONSOLE_USER}"
OUT="$USER_HOME/Desktop/x395-remote-$STAMP"
mkdir -p "$OUT"
chmod 700 "$OUT"

# Enable SSH / Remote Login. Newer macOS versions may reject systemsetup
# even when the terminal appears in Full Disk Access. In that case, enable
# and start Apple's own sshd LaunchDaemon directly.
if ! /usr/sbin/systemsetup -setremotelogin on; then
  echo "systemsetupが拒否したため、launchctl経由でSSHを有効化します。" >&2
  SSH_PLIST="/System/Library/LaunchDaemons/ssh.plist"
  if [[ -f "$SSH_PLIST" ]]; then
    /bin/launchctl enable system/com.openssh.sshd || true
    /bin/launchctl bootstrap system "$SSH_PLIST" 2>/dev/null || true
    /bin/launchctl kickstart -k system/com.openssh.sshd 2>/dev/null || true
  else
    echo "SSHのLaunchDaemonが見つかりません: $SSH_PLIST" >&2
    exit 1
  fi
fi

# Allow the currently logged-in user to use SSH.
/usr/sbin/dseditgroup -o edit -a "$CONSOLE_USER" -t user com.apple.access_ssh

# Optional GUI access. SSH remains the preferred method for early boot testing.
if [[ "$SCREEN_SHARING" -eq 1 ]]; then
  /bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist 2>/dev/null || true
fi

# Collect non-secret diagnostics. Do not include serial numbers or MAC addresses intentionally.
{
  echo "timestamp=$STAMP"
  echo "user=$CONSOLE_USER"
  echo "wifi_interface=$WIFI_IF"
  echo "hostname=$(scutil --get LocalHostName 2>/dev/null || hostname)"
  echo "wifi_ip=$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null || true)"
  echo
  echo "--- remote login ---"
  systemsetup -getremotelogin 2>&1 || true
  echo
  echo "--- wifi info ---"
  networksetup -getinfo "Wi-Fi" 2>&1 || true
  echo
  echo "--- ssh service ---"
  launchctl print system/com.openssh.sshd 2>&1 | sed -n '1,80p' || true
} | tee "$OUT/remote-status.txt"

sw_vers > "$OUT/sw_vers.txt"
sysctl -n machdep.cpu.brand_string > "$OUT/cpu.txt" 2>/dev/null || true
system_profiler SPHardwareDataType SPDisplaysDataType SPUSBDataType SPAudioDataType SPNetworkDataType > "$OUT/hardware.txt" 2>/dev/null || true
diskutil list > "$OUT/diskutil-list.txt" 2>/dev/null || true
chown -R "$CONSOLE_USER":staff "$OUT" 2>/dev/null || true

# Save the current OpenCore directory if it is mounted. This is a best-effort backup.
for EFI_ROOT in /Volumes/EFI /Volumes/*/EFI; do
  if [[ -d "$EFI_ROOT/OC" ]]; then
    mkdir -p "$OUT/EFI"
    ditto "$EFI_ROOT/OC" "$OUT/EFI/OC"
    echo "OpenCoreバックアップ: $EFI_ROOT/OC -> $OUT/EFI/OC"
    break
  fi
done

WIFI_IP="$(ipconfig getifaddr "$WIFI_IF" 2>/dev/null || true)"
HOST="$(scutil --get LocalHostName 2>/dev/null || hostname)"

echo
echo "完了しました。"
echo "SSH: $CONSOLE_USER@$HOST.local"
if [[ -n "$WIFI_IP" ]]; then
  echo "IP : ssh $CONSOLE_USER@$WIFI_IP"
else
  echo "Wi-FiのIPを取得できませんでした。次を確認してください: ipconfig getifaddr $WIFI_IF"
fi
echo "診断保存先: $OUT"
echo
echo "別PCからの接続例:"
echo "  ssh $CONSOLE_USER@$HOST.local"
echo "または"
if [[ -n "$WIFI_IP" ]]; then
  echo "  ssh $CONSOLE_USER@$WIFI_IP"
fi
echo
echo "macOS 27へ切り替える前に、上記SSH接続を別PCから一度テストしてください。"
