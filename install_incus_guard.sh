#!/usr/bin/env bash
# install_incus_guard.sh
# 一键部署 incus-guard-v2.sh + gua 管理命令
# 用法：
#   curl -fsSL https://你的短链/install.sh | sudo bash
#   sudo bash install_incus_guard.sh --dry-run
#   sudo bash install_incus_guard.sh --uninstall
set -euo pipefail

# ===== 【必改】改成你自己的 GitHub raw 地址或短链，用于 gua 菜单里的"脚本升级" =====
REMOTE_INSTALL_URL="REMOTE_INSTALL_URL="https://raw.githubusercontent.com/mesta1122/incus-guard/main/install_incus_guard.sh"

SCRIPT_PATH="/usr/local/sbin/incus-guard-v2.sh"
INSTALLER_PATH="/usr/local/sbin/install_incus_guard.sh"
GUA_BIN="/usr/local/bin/gua"
LOG_DIR="/var/log/incus-guard"
SYSTEMD_SERVICE="/etc/systemd/system/incus-guard.service"
SYSTEMD_TIMER="/etc/systemd/system/incus-guard.timer"

MODE="install"
DRY_RUN_FLAG=0
for arg in "${@:-}"; do
case "$arg" in
--dry-run) DRY_RUN_FLAG=1 ;;
--uninstall) MODE="uninstall" ;;
esac
done

if [ "$(id -u)" -ne 0 ]; then
echo "请用 root 权限运行: sudo bash $0" >&2
exit 1
fi

uninstall_all() {
echo "==> 停止并移除 systemd timer/service"
systemctl disable --now incus-guard.timer 2>/dev/null || true
rm -f "$SYSTEMD_SERVICE" "$SYSTEMD_TIMER"
systemctl daemon-reload
echo "==> 移除主脚本与管理命令（日志保留）"
rm -f "$SCRIPT_PATH" "$GUA_BIN" "$INSTALLER_PATH"
echo "完成。如需清理 iptables 规则，请手动检查 iptables -L INCUS_GUARD -n"
}

if [ "$MODE" = "uninstall" ]; then
uninstall_all
exit 0
fi

echo "==> 检查依赖"
MISSING=()
command -v incus >/dev/null 2>&1 || MISSING+=(incus)
command -v conntrack >/dev/null 2>&1 || MISSING+=(conntrack)
command -v iptables >/dev/null 2>&1 || MISSING+=(iptables)

if [ "${#MISSING[@]}" -gt 0 ]; then
echo "缺少: ${MISSING[*]}"
if command -v apt-get >/dev/null 2>&1; then
echo "尝试通过 apt 安装 conntrack / iptables（incus 需按官方文档自行安装）"
apt-get update -y
apt-get install -y conntrack iptables || true
else
echo "非 apt 系统，请先手动安装缺失依赖后重新运行本脚本" >&2
fi
fi

echo "==> 保存安装脚本自身，供后续升级/卸载使用"
install -d -m 755 "$(dirname "$INSTALLER_PATH")"
cp -f "$0" "$INSTALLER_PATH" 2>/dev/null || curl -fsSL "$REMOTE_INSTALL_URL" -o "$INSTALLER_PATH"
chmod 750 "$INSTALLER_PATH"

echo "==> 写入主脚本 $SCRIPT_PATH"
install -d -m 755 "$(dirname "$SCRIPT_PATH")"
cat > "$SCRIPT_PATH" << 'GUARD_EOF'
#!/usr/bin/env bash
set -u

PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

TH_DST_IP=${TH_DST_IP:-80}
TH_PORTS=${TH_PORTS:-50}
TH_TOTAL=${TH_TOTAL:-1000}
TH_SYN_SENT=${TH_SYN_SENT:-150}

STOP_DST_IP=${STOP_DST_IP:-250}
STOP_PORTS=${STOP_PORTS:-120}
STOP_TOTAL=${STOP_TOTAL:-3000}
STOP_SYN_SENT=${STOP_SYN_SENT:-500}

COOLDOWN_SECONDS=${COOLDOWN_SECONDS:-1800}
BAN_SECONDS=${BAN_SECONDS:-86400}
DRY_RUN=${DRY_RUN:-0}

LOG_DIR="/var/log/incus-guard"
LOG="$LOG_DIR/incus_guard.log"
COOLDOWN_FILE="/run/incus_guard.cooldown"
BAN_FILE="/run/incus_guard.bans"
LOCK_FILE="/run/incus_guard.lock"
BAN_CHAIN="INCUS_GUARD"

mkdir -p "$LOG_DIR"
touch "$COOLDOWN_FILE" "$BAN_FILE"

log() {
printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
}

exec 9>"$LOCK_FILE"
flock -n 9 || exit 0

command -v incus >/dev/null 2>&1 || { log "incus not found"; exit 1; }
command -v conntrack >/dev/null 2>&1 || { log "conntrack not found"; exit 1; }

IPTABLES="$(command -v iptables || true)"

ensure_chain() {
[ -n "$IPTABLES" ] || return 1
"$IPTABLES" -N "$BAN_CHAIN" 2>/dev/null || true
"$IPTABLES" -C FORWARD -j "$BAN_CHAIN" 2>/dev/null || \
"$IPTABLES" -I FORWARD 1 -j "$BAN_CHAIN"
}

ban_ip() {
local ip="$1"
[ -n "$IPTABLES" ] || { log "iptables not found, skip ban $ip"; return 0; }
ensure_chain || return 0
if [ "$DRY_RUN" = "1" ]; then
log "[DRY_RUN] ban ip $ip"
return 0
fi
"$IPTABLES" -C "$BAN_CHAIN" -s "$ip" -j DROP 2>/dev/null || \
"$IPTABLES" -A "$BAN_CHAIN" -s "$ip" -j DROP
}

record_ban() {
local name="$1" ip="$2" now="$3"
local tmp
tmp="$(mktemp)"
grep -v " $ip " "$BAN_FILE" 2>/dev/null > "$tmp" || true
printf '%s %s %s\n' "$name" "$ip" "$now" >> "$tmp"
mv "$tmp" "$BAN_FILE"
}

cleanup_bans() {
[ -n "$IPTABLES" ] || return 0
ensure_chain || return 0
local now tmp name ip ts
now="$(date +%s)"
tmp="$(mktemp)"
while read -r name ip ts; do
[ -z "${name:-}" ] && continue
if [ "$((now - ts))" -gt "$BAN_SECONDS" ]; then
if [ "$DRY_RUN" = "1" ]; then
log "[DRY_RUN] unban expired $ip"
else
"$IPTABLES" -D "$BAN_CHAIN" -s "$ip" -j DROP 2>/dev/null || true
fi
log "unban expired $name $ip"
else
printf '%s %s %s\n' "$name" "$ip" "$ts" >> "$tmp"
fi
done < "$BAN_FILE"
mv "$tmp" "$BAN_FILE"
}

cleanup_cooldown() {
local now tmp name ts
now="$(date +%s)"
tmp="$(mktemp)"
while read -r name ts; do
[ -z "${name:-}" ] && continue
if [ "$((now - ts))" -lt "$COOLDOWN_SECONDS" ]; then
printf '%s %s\n' "$name" "$ts" >> "$tmp"
fi
done < "$COOLDOWN_FILE"
mv "$tmp" "$COOLDOWN_FILE"
}

in_cooldown() {
local name="$1" now ts
now="$(date +%s)"
ts="$(awk -v n="$name" '$1 == n { print $2; exit }' "$COOLDOWN_FILE" 2>/dev/null)"
[ -n "$ts" ] && [ "$((now - ts))" -lt "$COOLDOWN_SECONDS" ]
}

set_cooldown() {
local name="$1" now tmp
now="$(date +%s)"
tmp="$(mktemp)"
awk -v n="$name" '$1 != n { print }' "$COOLDOWN_FILE" 2>/dev/null > "$tmp" || true
printf '%s %s\n' "$name" "$now" >> "$tmp"
mv "$tmp" "$COOLDOWN_FILE"
}

get_field() {
incus list "$1" --format csv -c "$2" 2>/dev/null | head -n 1
}

get_ipv4() {
get_field "$1" 4 | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -n 1
}

stats_for_ip() {
local ip="$1"
printf '%s\n' "$CT4" | awk -v ip="$ip" '
function getv(s) { sub(/^[^=]+=/, "", s); return s }
{
os=""; od=""; odp="";
for (i=1; i<=NF; i++) {
if ($i ~ /^src=/ && os == "") os=getv($i);
else if ($i ~ /^dst=/ && od == "") od=getv($i);
else if ($i ~ /^dport=/ && odp == "") odp=getv($i);
}
if (os == ip) {
total++;
if (od != "") dst[od]=1;
if (odp != "") port[odp]=1;
if ($0 ~ /SYN_SENT/) syn++;
}
}
END {
for (d in dst) dc++;
for (p in port) pc++;
printf "%d %d %d %d\n", total+0, dc+0, pc+0, syn+0;
}'
}

save_evidence() {
local name="$1" ip="$2" file
file="$LOG_DIR/incus_${name}_$(date '+%Y%m%d_%H%M%S')_abuse.log"
printf '%s\n' "$CT4" | awk -v ip="$ip" '
function getv(s) { sub(/^[^=]+=/, "", s); return s }
{
os="";
for (i=1; i<=NF; i++) {
if ($i ~ /^src=/ && os == "") os=getv($i);
}
if (os == ip) print;
}' > "$file"
log "evidence saved: $file"
}

cleanup_cooldown
cleanup_bans

CT4="$(conntrack -L -f ipv4 2>/dev/null || true)"
log "===== START ====="

for NAME in $(incus list --format csv -c n); do
STATE="$(get_field "$NAME" s)"
TYPE="$(get_field "$NAME" t)"

[ "$STATE" = "RUNNING" ] || continue
[ "$TYPE" = "CONTAINER" ] || continue

IP="$(get_ipv4 "$NAME")"
[ -n "$IP" ] || continue

read -r TOTAL DST_IP PORTS SYN_SENT < <(stats_for_ip "$IP")

log "$NAME ip=$IP total=$TOTAL dst=$DST_IP ports=$PORTS syn_sent=$SYN_SENT"

ABUSE=0
REASON=""

[ "$DST_IP" -gt "$TH_DST_IP" ] && ABUSE=1 && REASON="$REASON dst_ip=$DST_IP"
[ "$PORTS" -gt "$TH_PORTS" ] && ABUSE=1 && REASON="$REASON ports=$PORTS"
[ "$TOTAL" -gt "$TH_TOTAL" ] && ABUSE=1 && REASON="$REASON total=$TOTAL"
[ "$SYN_SENT" -gt "$TH_SYN_SENT" ] && ABUSE=1 && REASON="$REASON syn_sent=$SYN_SENT"

[ "$ABUSE" -eq 1 ] || continue

log "[ALERT] $NAME ip=$IP abuse:$REASON"

if in_cooldown "$NAME"; then
log "$NAME in cooldown, skip action"
continue
fi

set_cooldown "$NAME"
save_evidence "$NAME" "$IP"

ACTION="freeze"
if [ "$TOTAL" -gt "$STOP_TOTAL" ] || \
[ "$DST_IP" -gt "$STOP_DST_IP" ] || \
[ "$PORTS" -gt "$STOP_PORTS" ] || \
[ "$SYN_SENT" -gt "$STOP_SYN_SENT" ]; then
ACTION="stop"
fi

ban_ip "$IP"
record_ban "$NAME" "$IP" "$(date +%s)"

if [ "$DRY_RUN" = "1" ]; then
log "[DRY_RUN] would $ACTION $NAME"
continue
fi

if [ "$ACTION" = "stop" ]; then
log "STOP $NAME"
incus stop "$NAME" --timeout 10 --force >> "$LOG" 2>&1 || true
else
log "FREEZE $NAME"
incus freeze "$NAME" >> "$LOG" 2>&1 || true
fi
done

log "===== END ====="
GUARD_EOF
chmod 750 "$SCRIPT_PATH"

echo "==> 创建日志目录 $LOG_DIR"
install -d -m 755 "$LOG_DIR"

echo "==> 写入 systemd service"
cat > "$SYSTEMD_SERVICE" << SERVICE_EOF
[Unit]
Description=Incus outbound abuse guard (scan/crawler/DDoS detection)
After=network.target

[Service]
Type=oneshot
ExecStart=$SCRIPT_PATH
$( [ "$DRY_RUN_FLAG" = "1" ] && echo "Environment=DRY_RUN=1" )
SERVICE_EOF

echo "==> 写入 systemd timer（每分钟跑一次）"
cat > "$SYSTEMD_TIMER" << 'TIMER_EOF'
[Unit]
Description=Run incus-guard every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

systemctl daemon-reload
systemctl enable --now incus-guard.timer

echo "==> 写入 gua 管理命令 $GUA_BIN"
cat > "$GUA_BIN" << GUA_EOF
#!/usr/bin/env bash
set -u
LOG_DIR="$LOG_DIR"
LOG="\$LOG_DIR/incus_guard.log"
BAN_FILE="/run/incus_guard.bans"
INSTALLER_PATH="$INSTALLER_PATH"
REMOTE_INSTALL_URL="$REMOTE_INSTALL_URL"

status_line() {
  if systemctl is-active --quiet incus-guard.timer; then
    echo "active"
  else
    echo "inactive"
  fi
}

pause() {
  read -rp "按回车返回菜单..." _
}

while true; do
  clear
  echo "================================"
  echo "   Incus Guard 管理面板"
  echo "   脚本运行情况: \$(status_line)"
  echo "================================"
  echo "1. 脚本升级（拉取最新版本并重装）"
  echo "2. 封禁日志"
  echo "3. 删除脚本（完全卸载）"
  echo "4. 退出"
  echo "================================"
  read -rp "请输入选项 [1-4]: " choice

  case "\$choice" in
    1)
      echo "==> 正在拉取最新版本并升级..."
      if curl -fsSL "\$REMOTE_INSTALL_URL" -o /tmp/install_incus_guard_latest.sh; then
        bash /tmp/install_incus_guard_latest.sh
        rm -f /tmp/install_incus_guard_latest.sh
        echo "==> 升级完成"
      else
        echo "下载失败，请检查网络或 REMOTE_INSTALL_URL 是否正确"
      fi
      pause
      ;;
    2)
      echo "==> 封禁记录 (name ip banned_at):"
      if [ -s "\$BAN_FILE" ]; then
        cat "\$BAN_FILE"
      else
        echo "暂无封禁记录"
      fi
      echo
      echo "==> 最近 40 行运行日志:"
      tail -n 40 "\$LOG" 2>/dev/null || echo "暂无日志"
      pause
      ;;
    3)
      read -rp "确认要完全卸载 incus-guard 吗？(y/N): " confirm
      if [ "\$confirm" = "y" ] || [ "\$confirm" = "Y" ]; then
        bash "\$INSTALLER_PATH" --uninstall
        echo "已卸载。gua 命令即将失效。"
        pause
        exit 0
      fi
      ;;
    4)
      exit 0
      ;;
    *)
      echo "无效选项"
      sleep 1
      ;;
  esac
done
GUA_EOF
chmod 755 "$GUA_BIN"

echo
echo "==> 安装完成"
[ "$DRY_RUN_FLAG" = "1" ] && echo "  当前为 DRY_RUN 模式：只记日志，不会 freeze/stop/封禁"
echo "  root 下输入 gua 打开管理面板"
echo "  状态: systemctl status incus-guard.timer"
echo "  日志: tail -f $LOG_DIR/incus_guard.log"
echo "  卸载: sudo bash $INSTALLER_PATH --uninstall"
