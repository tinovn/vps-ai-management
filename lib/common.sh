#!/bin/bash
# =============================================================================
# lib/common.sh — ham dung chung cho install.sh va cac module
# (logging, apt-lock, domain/DNS, .env helpers, Node.js, swap, UFW)
# =============================================================================

readonly VPS_AI_VERSION="0.1.0"
readonly VPS_AI_DIR="/opt/vps-ai"
readonly VPS_AI_ENV="${VPS_AI_DIR}/.env"
readonly LOG_FILE="/var/log/vps-ai-install.log"
readonly NODE_MAJOR_TARGET=24
readonly CADDY_SITES_DIR="/etc/vps-ai/caddy/sites"

# Cong cua cac management API (giu nguyen nhu repo goc de HostBill khong phai doi)
readonly HERMES_MGMT_PORT=9997
readonly OPENCLAW_MGMT_PORT=9998
readonly N8N_AGENT_PORT=7071

export DEBIAN_FRONTEND=noninteractive

# ---- Logging ------------------------------------------------------------------
mkdir -p "$(dirname "$LOG_FILE")"
# Duoi bootstrap (stdout da redirect vao $LOG_FILE) thi khong tee de tranh ghi doi
if [[ "${VPS_AI_LOG_REDIRECTED:-0}" == "1" ]]; then
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2; }
else
  log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE" >&2; }
fi
step() { log ""; log "==== $* ===="; }
die()  { log "FATAL: $*"; exit 1; }

# ---- .env helpers -------------------------------------------------------------
# read_env_value <file> <key> — rong neu file/key khong co
read_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || { echo ""; return 0; }
  awk -F= -v k="$key" '$1 == k { sub("^[^=]*=", ""); print; exit }' "$file"
}

# upsert_env <file> <key> <value> — ghi de neu da co, them neu chua
upsert_env() {
  local file="$1" key="$2" value="$3"
  mkdir -p "$(dirname "$file")"
  touch "$file"
  chmod 600 "$file"
  if grep -q "^${key}=" "$file" 2>/dev/null; then
    local tmp
    tmp="$(mktemp)"
    awk -v k="$key" -v v="$value" -F= '$1 == k { print k "=" v; next } { print }' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

# ---- Pre-flight -----------------------------------------------------------------
preflight_checks() {
  [[ "$(id -u)" == "0" ]] || die "Phai chay bang root"
  [[ -f /etc/os-release ]] || die "/etc/os-release khong ton tai"
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || die "Chi ho tro Ubuntu (dang chay: ${PRETTY_NAME:-unknown})"
  if [[ "${WANT_HERMES:-false}" == "true" && "${VERSION_ID:-}" != "24.04" ]]; then
    die "Hermes yeu cau Ubuntu 24.04 (dang chay: ${PRETTY_NAME})"
  fi
  if [[ "${VERSION_ID:-}" != "24.04" && "${VERSION_ID:-}" != "22.04" ]]; then
    die "Ho tro Ubuntu 22.04/24.04 (dang chay: ${PRETTY_NAME})"
  fi
  log "OS: ${PRETTY_NAME} ($(dpkg --print-architecture))"

  local need_disk=2 need_ram=1024 disk ram
  [[ "${WANT_HERMES:-false}" == "true" ]]   && need_disk=$((need_disk + 6)) && need_ram=$((need_ram + 1536))
  [[ "${WANT_N8N:-false}" == "true" ]]      && need_disk=$((need_disk + 6)) && need_ram=$((need_ram + 1536))
  [[ "${WANT_OPENCLAW:-false}" == "true" ]] && need_disk=$((need_disk + 4)) && need_ram=$((need_ram + 1024))
  disk=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
  ram=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo)
  MEM_TOTAL_MB="$ram"
  log "Tai nguyen: disk trong=${disk}GB (can ~${need_disk}GB), RAM=${ram}MB (khuyen nghi ~${need_ram}MB)"
  [[ "${disk:-0}" -ge "$need_disk" ]] || die "Khong du dung luong dia: can >=${need_disk}GB, con ${disk}GB"
  [[ "${ram:-0}" -ge 900 ]] || die "Khong du RAM: can >=1GB, co ${ram}MB"
  if [[ "$ram" -lt "$need_ram" ]]; then
    log "CANH BAO: RAM ${ram}MB thap hon khuyen nghi ${need_ram}MB cho bo app da chon — se them swap, app co the cham"
  fi
}

# ---- apt lock (VPS moi hay bi unattended-upgrades giu lock) ---------------------
is_apt_locked() {
  if command -v lsof &>/dev/null; then
    lsof /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null | grep -q .
    return $?
  fi
  fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null
}

force_release_apt() {
  killall -9 apt apt-get dpkg unattended-upgr 2>/dev/null || true
  rm -f /var/lib/dpkg/lock /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock 2>/dev/null || true
  rm -f /var/lib/dpkg/updates/* 2>/dev/null || true
  dpkg --force-confdef --force-confold --configure -a 2>/dev/null || true
}

wait_for_apt() {
  local max=180 waited=0
  while [[ $waited -lt $max ]]; do
    is_apt_locked || return 0
    log "apt dang bi lock, cho 5s (${waited}s/${max}s)..."
    sleep 5
    waited=$((waited + 5))
  done
  log "WARN: apt van lock sau ${max}s, ep giai phong"
  force_release_apt
}

apt_retry() {
  local retries=3 i=0
  while [[ $i -lt $retries ]]; do
    wait_for_apt
    if "$@"; then return 0; fi
    i=$((i + 1))
    log "apt retry ${i}/${retries}: don lock + cau hinh lai dpkg..."
    force_release_apt
    sleep 5
  done
  log "LOI: apt that bai sau ${retries} lan: $*"
  return 1
}

apt_install() {
  apt_retry apt-get -qqy -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install "$@"
}

prepare_apt() {
  systemctl stop unattended-upgrades 2>/dev/null || true
  systemctl disable unattended-upgrades 2>/dev/null || true
  systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl disable apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
  systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service unattended-upgrades.service 2>/dev/null || true
  sleep 2
  force_release_apt
  wait_for_apt
}

# ---- IP / domain / DNS --------------------------------------------------------------
resolve_server_ip() {
  SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ -z "$SERVER_IP" ]]; then
    SERVER_IP=$(curl -sf --max-time 5 https://api.ipify.org 2>/dev/null || echo "127.0.0.1")
  fi
  log "Server IP: ${SERVER_IP}"
}

# Ten mien goc: --domain > /opt/vps-ai/.env > hostname -f > <ip>.sslip.io
resolve_base_domain() {
  local arg="$1" existing fqdn
  existing="$(read_env_value "$VPS_AI_ENV" BASE_DOMAIN)"
  if [[ -n "$arg" ]]; then
    BASE_DOMAIN="$arg"
  elif [[ -n "$existing" ]]; then
    BASE_DOMAIN="$existing"
  else
    fqdn=$(hostname -f 2>/dev/null || hostname)
    if [[ "$fqdn" == *.* && "$fqdn" != localhost* && ! "$fqdn" =~ \.(local|localdomain|internal|lan)$ ]]; then
      BASE_DOMAIN="$fqdn"
    else
      BASE_DOMAIN="${SERVER_IP}.sslip.io"
    fi
  fi
  BASE_DOMAIN="$(echo "$BASE_DOMAIN" | tr '[:upper:]' '[:lower:]' | sed -E 's#^https?://##; s#/.*$##')"
  log "Ten mien goc: ${BASE_DOMAIN}"
}

# Phan giai A record qua DoH 1.1.1.1 (bo qua /etc/hosts — Ubuntu hay map hostname ve 127.0.1.1)
resolve_domain() {
  local d="$1" r=""
  r=$(curl -sf --max-time 5 "https://1.1.1.1/dns-query?name=${d}&type=A" \
      -H "accept: application/dns-json" 2>/dev/null \
    | grep -oE '"data":[ ]*"[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+"' \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ') || true
  if [[ -z "$r" ]]; then
    r=$(getent ahostsv4 "$d" 2>/dev/null | awk '$1 !~ /^127\./ {print $1}' | sort -u | tr '\n' ' ') || true
  fi
  echo "$r"
}

# dns_points_here <domain> [tries] — 0 neu domain tro ve SERVER_IP
dns_points_here() {
  local d="$1" tries="${2:-6}" i resolved
  [[ "$d" == *.sslip.io ]] && return 0
  for ((i = 1; i <= tries; i++)); do
    resolved="$(resolve_domain "$d")"
    if [[ " ${resolved} " == *" ${SERVER_IP} "* ]]; then
      log "DNS OK: ${d} -> ${SERVER_IP}"
      return 0
    fi
    log "DNS ${i}/${tries}: ${d} -> ${resolved:-?} (can ${SERVER_IP})"
    [[ $i -lt $tries ]] && sleep 5
  done
  return 1
}

# Danh sach app da cai (tu lan chay truoc) + app dang chon
installed_apps() { read_env_value "$VPS_AI_ENV" INSTALLED_APPS | tr ',' ' '; }

mark_installed() {
  local app="$1" apps
  apps="$(installed_apps)"
  [[ " $apps " == *" $app "* ]] && return 0
  apps="$(echo "$apps $app" | xargs | tr ' ' ',')"
  upsert_env "$VPS_AI_ENV" INSTALLED_APPS "$apps"
}

total_app_count() {
  local all
  all="$(installed_apps)"
  [[ "${WANT_HERMES:-false}" == "true" ]]   && all="$all hermes"
  [[ "${WANT_N8N:-false}" == "true" ]]      && all="$all n8n"
  [[ "${WANT_OPENCLAW:-false}" == "true" ]] && all="$all openclaw"
  echo "$all" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l | tr -d ' '
}

# Ten mien da luu trong .env cua app (lan cai truoc) — de khong doi domain khi cai them app
existing_app_domain() {
  local d=""
  case "$1" in
    hermes)   d="$(read_env_value /opt/hermes/.env DOMAIN)" ;;
    openclaw) d="$(read_env_value /opt/openclaw/.env DOMAIN)" ;;
    n8n)      d="$(read_env_value /opt/n8n/.env N8N_HOST)" ;;
  esac
  [[ "$d" == http://* ]] && d=""
  echo "$d"
}

# app_domain <app> <override> — override > domain cu > (1 app: goc | nhieu app: <app>.<goc>)
app_domain() {
  local app="$1" override="$2" existing
  if [[ -n "$override" ]]; then echo "$override"; return; fi
  existing="$(existing_app_domain "$app")"
  if [[ -n "$existing" ]]; then echo "$existing"; return; fi
  if [[ "$(total_app_count)" -le 1 ]]; then
    echo "$BASE_DOMAIN"
  else
    echo "${app}.${BASE_DOMAIN}"
  fi
}

# Shared env: key quan ly + email ACME dung chung cho moi app
init_shared_env() {
  local key_arg="$1" email_arg="$2" existing_key existing_email
  mkdir -p "$VPS_AI_DIR"
  existing_key="$(read_env_value "$VPS_AI_ENV" MGMT_API_KEY)"
  existing_email="$(read_env_value "$VPS_AI_ENV" ACME_EMAIL)"
  # --mgmt-key thang (HostBill la nguon su that), roi gia tri cu, roi tu sinh
  MGMT_API_KEY="${key_arg:-${existing_key:-$(openssl rand -hex 32)}}"
  local default_email="admin@${BASE_DOMAIN}"
  # sslip.io khong nhan mail — dung mac dinh cua n8n-manage goc
  [[ "$BASE_DOMAIN" == *.sslip.io ]] && default_email="noreply@tino.org"
  ACME_EMAIL="${email_arg:-${existing_email:-$default_email}}"
  upsert_env "$VPS_AI_ENV" VPS_AI_VERSION "$VPS_AI_VERSION"
  upsert_env "$VPS_AI_ENV" BASE_DOMAIN "$BASE_DOMAIN"
  upsert_env "$VPS_AI_ENV" SERVER_IP "$SERVER_IP"
  upsert_env "$VPS_AI_ENV" MGMT_API_KEY "$MGMT_API_KEY"
  upsert_env "$VPS_AI_ENV" ACME_EMAIL "$ACME_EMAIL"
  log "MGMT_API_KEY: $([[ -n "$key_arg" ]] && echo "tu --mgmt-key" || ([[ -n "$existing_key" ]] && echo "giu nguyen" || echo "tu sinh"))"
}

# ---- Goi he thong ----------------------------------------------------------------
install_base_packages() {
  # Repo cloudsmith cu cua Caddy tra 402 / het han key -> lam hong moi apt-get update
  rm -f /etc/apt/sources.list.d/caddy-stable.list /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  apt_retry apt-get -qqy update
  apt_retry apt-get -qqy -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold upgrade
  apt_install curl ca-certificates gnupg lsb-release ufw fail2ban jq dnsutils git openssl \
    build-essential libssl-dev libffi-dev python3-venv python3-pip ffmpeg \
    debian-keyring debian-archive-keyring apt-transport-https libatomic1 unzip xz-utils lsof psmisc
  systemctl enable --now fail2ban 2>/dev/null || true
}

ensure_swap() {
  if swapon --show 2>/dev/null | grep -q .; then
    log "Swap da co, bo qua"
    return 0
  fi
  local size="2G"
  [[ "$(total_app_count)" -ge 2 ]] && size="4G"
  log "Chua co swap -> tao /swapfile ${size} (chong OOM khi build Hermes / Docker image)"
  if fallocate -l "$size" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$(( ${size%G} * 1024 )) status=none; then
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile || log "WARN: khong bat duoc swap"
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  else
    log "WARN: khong tao duoc swapfile"
  fi
}

# Mot so nha cung cap cap IPv6 nhung khong dinh tuyen ra internet -> Python/httpx
# treo ~30s moi request. Neu IPv6 egress hong thi uu tien IPv4 toan he thong.
fix_ipv6_preference() {
  if grep -qE '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96' /etc/gai.conf 2>/dev/null; then
    return 0
  fi
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6' || return 0
  if curl -6 -sS -m 6 -o /dev/null https://cloudflare.com 2>/dev/null; then
    return 0
  fi
  log "IPv6 co dia chi nhung egress hong — uu tien IPv4 trong /etc/gai.conf"
  printf '\n# Prefer IPv4 (broken IPv6 egress) — vps-ai-management %s\nprecedence ::ffff:0:0/96  100\n' \
    "$(date +%F)" >> /etc/gai.conf
}

# Node.js dung chung: OpenClaw can >= 24; Hermes (Zalo sidecar, WhatsApp bridge)
# va n8n-agent chay tot tren 24. Cai 1 lan, khong ha cap.
install_nodejs() {
  local major=0
  command -v node &>/dev/null && major="$(node -v | sed -E 's/^v([0-9]+).*/\1/')"
  if [[ "$major" -lt "$NODE_MAJOR_TARGET" ]]; then
    log "Cai Node.js ${NODE_MAJOR_TARGET} (hien tai: ${major})"
    curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_TARGET}.x" | bash - >>"$LOG_FILE" 2>&1
    apt_install nodejs
  fi
  log "Node: $(node -v) / npm: $(npm -v)"
}

ufw_allow() {
  local rule="$1" comment="$2"
  ufw status 2>/dev/null | grep -qE "^${rule}\b" || ufw allow "$rule" comment "$comment" >/dev/null
}

setup_firewall_base() {
  if ! ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
  fi
  ufw_allow 80/tcp http
  ufw_allow 443/tcp https
  ufw status 2>/dev/null | grep -q "22/tcp.*LIMIT" || ufw limit ssh/tcp >/dev/null
  ufw --force enable >/dev/null
  log "UFW: 22 (limit), 80, 443"
}

install_cli() {
  install -m 0755 "${SELF_DIR}/bin/vps-ai" /usr/local/bin/vps-ai
  # Giu ban source hien tai de chay lai / cai them app ma khong can tai lai
  if [[ "$SELF_DIR" != "${VPS_AI_DIR}/src" ]]; then
    rm -rf "${VPS_AI_DIR}/src"
    mkdir -p "${VPS_AI_DIR}/src"
    cp -a "${SELF_DIR}/." "${VPS_AI_DIR}/src/"
  fi
}

cleanup_apt() {
  apt-get -qqy autoremove >/dev/null 2>&1 || true
  apt-get -qqy autoclean >/dev/null 2>&1 || true
}

# wait_http <url> <tries> <sleep> — 0 khi URL tra 2xx
wait_http() {
  local url="$1" tries="${2:-24}" delay="${3:-5}" i
  for ((i = 1; i <= tries; i++)); do
    curl -fs -o /dev/null --max-time 5 "$url" && return 0
    sleep "$delay"
  done
  return 1
}
