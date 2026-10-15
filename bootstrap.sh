#!/bin/bash
# =============================================================================
# vps-ai-management bootstrap — cho HostBill / cloud-init / SSH timeout ngan
#
#   ssh root@vps "curl -fsSL https://raw.githubusercontent.com/tinovn/vps-ai-management/main/bootstrap.sh | \
#     bash -s -- --domain <TEN_MIEN> [--mgmt-key <KEY>] --hermes --n8n --openclaw"
#
# Nhan moi flag cua install.sh. Luong:
#   1. Detach khoi SSH (setsid + nohup), caller thay exit 0 ngay
#   2. Cho cloud-init xong
#   3. Tai source repo -> /opt/vps-ai/src, luu args
#   4. Tao systemd oneshot + timer OnBootSec, reboot
#   5. Sau reboot install.sh chay 1 lan roi tu don dep
#
# Theo doi: tail -f /var/log/vps-ai-install.log
# =============================================================================
set -euo pipefail

readonly REPO="tinovn/vps-ai-management"
readonly BOOT_DIR="/opt/vps-ai"
readonly SRC_DIR="${BOOT_DIR}/src"
readonly ARGS_FILE="${BOOT_DIR}/install.args"
readonly LOG_FILE="/var/log/vps-ai-install.log"
readonly SERVICE_NAME="vps-ai-install"

ref="main"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == "--ref" ]] && ref="${args[$((i + 1))]:-main}"
done

# ---- Detach khoi SSH session (HostBill goi voi timeout ~30s) ------------------
if [[ "${VPS_AI_BOOTSTRAP_DETACHED:-0}" != "1" ]]; then
  mkdir -p "$BOOT_DIR" "$(dirname "$LOG_FILE")"
  self="${BOOT_DIR}/.bootstrap.sh"
  if [[ -f "$0" && "$0" != "bash" && "$0" != "-bash" ]]; then
    cp -f "$0" "$self"
  else
    curl -fsSL "https://raw.githubusercontent.com/${REPO}/${ref}/bootstrap.sh" -o "$self" \
      || { echo "FATAL: tai lai bootstrap.sh loi" >&2; exit 1; }
  fi
  chmod +x "$self"
  VPS_AI_BOOTSTRAP_DETACHED=1 setsid nohup bash "$self" "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  disown 2>/dev/null || true
  echo "vps-ai-bootstrap: da detach (pid $!). Theo doi: tail -f $LOG_FILE"
  exit 0
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] bootstrap: $*" >&2; }
log "=== vps-ai-management bootstrap ==="

# ---- 1. Cho cloud-init (exit 2 = warning van coi la xong) -----------------------
if command -v cloud-init &>/dev/null; then
  log "Cho cloud-init (toi da ${CLOUD_INIT_WAIT:-300}s)..."
  set +e
  timeout "${CLOUD_INIT_WAIT:-300}" cloud-init status --wait >/dev/null 2>&1
  rc=$?
  set -e
  case "$rc" in
    0|2) log "cloud-init xong (exit=${rc})" ;;
    124) log "WARN: cloud-init qua ${CLOUD_INIT_WAIT:-300}s chua xong, tiep tuc" ;;
    *)   log "WARN: cloud-init exit ${rc}, tiep tuc" ;;
  esac
fi

# ---- 2. Tai source + luu args ---------------------------------------------------
log "Tai ${REPO}@${ref}"
tmp="$(mktemp -d)"
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${ref}" | tar -xz -C "$tmp" \
  || { log "FATAL: tai source loi"; exit 1; }
rm -rf "$SRC_DIR"
mv "$tmp"/* "$SRC_DIR"
rm -rf "$tmp"
printf '%q ' "$@" > "$ARGS_FILE"
log "Args: $(cat "$ARGS_FILE")"

# ---- 3. Oneshot service + timer (chac chan chay sau reboot) ----------------------
# Logic nam trong script rieng: systemd tu thay the $var trong ExecStart.
cat > "${BOOT_DIR}/run-install.sh" <<EOF
#!/bin/bash
eval "set -- \$(cat ${ARGS_FILE})"
VPS_AI_LOG_REDIRECTED=1 bash ${SRC_DIR}/install.sh "\$@" >> ${LOG_FILE} 2>&1
rc=\$?
systemctl disable ${SERVICE_NAME}.timer
rm -f /etc/systemd/system/${SERVICE_NAME}.timer /etc/systemd/system/${SERVICE_NAME}.service ${ARGS_FILE} ${BOOT_DIR}/run-install.sh
systemctl daemon-reload
exit \$rc
EOF
chmod +x "${BOOT_DIR}/run-install.sh"

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=vps-ai-management one-shot installer (chay 1 lan sau reboot)
After=network-online.target
Wants=network-online.target
ConditionPathExists=${SRC_DIR}/install.sh

[Service]
Type=oneshot
RemainAfterExit=no
Environment=DEBIAN_FRONTEND=noninteractive
Environment=HOME=/root
ExecStart=/bin/bash ${BOOT_DIR}/run-install.sh
TimeoutStartSec=60min
EOF

cat > "/etc/systemd/system/${SERVICE_NAME}.timer" <<EOF
[Unit]
Description=Chay vps-ai-management installer sau khi boot

[Timer]
OnBootSec=20s
AccuracySec=1s
Unit=${SERVICE_NAME}.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable "${SERVICE_NAME}.timer"
log "Da len lich. Reboot sau 5s..."
nohup bash -c 'sleep 5 && systemctl reboot' >/dev/null 2>&1 &
exit 0
