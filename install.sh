#!/bin/bash
# =============================================================================
# vps-ai-management — cai Hermes Agent / n8n / OpenClaw tren 1 VPS (Ubuntu 24.04)
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tinovn/vps-ai-management/main/install.sh | \
#     bash -s -- --domain <TEN_MIEN> [--mgmt-key <KEY>] --hermes --n8n --openclaw
#
# Chon app (it nhat 1, co the chay lai de cai them app):
#   --hermes             Hermes Agent + management API (:9997)
#   --n8n                n8n (Docker) + n8n-agent (:7071)
#   --openclaw           OpenClaw gateway + management API (:9998)
#   --all                Ca 3 app
#
# Chung:
#   --domain <FQDN>      Ten mien goc. 1 app -> dung chinh ten mien nay;
#                        nhieu app -> hermes.<FQDN>, n8n.<FQDN>, openclaw.<FQDN>
#                        (bo trong: hostname -f, roi <ip>.sslip.io)
#   --mgmt-key <KEY>     API key dung chung cho ca 3 management API (tu sinh neu bo trong)
#   --email <EMAIL>      Email Let's Encrypt (mac dinh admin@<domain>)
#   --hermes-domain <D>  Ghi de ten mien rieng cho tung app
#   --n8n-domain <D>
#   --openclaw-domain <D>
#   --ref <GIT_REF>      Ref cua repo vps-ai-management (mac dinh main)
#
# Tuy chon rieng:
#   --hermes-ref <REF>   Ref upstream NousResearch/hermes-agent (mac dinh main)
#   --skip-zalo          Hermes: khong cai plugin Zalo ca nhan
#   --no-rag             Hermes: khong cai RAG MCP service
#   --n8n-ref <REF>      Ref tinovn/n8n-manage (mac dinh main)
#   --ips <CIDR,...>     n8n-agent: IP/CIDR duoc phep goi API
#
# Log: /var/log/vps-ai-install.log
# =============================================================================

set -euo pipefail
export HOME="${HOME:-/root}"

readonly VPS_AI_REPO="tinovn/vps-ai-management"

# ---- Tu tai source khi chay qua `curl | bash` --------------------------------
# lib/ va modules/ khong co san khi script duoc pipe tu curl -> tai tarball repo
# ve /opt/vps-ai/src roi re-exec ban day du.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
if [[ -z "$SELF_DIR" || ! -f "${SELF_DIR}/lib/common.sh" ]]; then
  ref="main"
  args=("$@")
  for ((i = 0; i < ${#args[@]}; i++)); do
    [[ "${args[$i]}" == "--ref" ]] && ref="${args[$((i + 1))]:-main}"
  done
  src="/opt/vps-ai/src"
  echo "vps-ai: tai ${VPS_AI_REPO}@${ref} -> ${src}"
  mkdir -p /opt/vps-ai
  tmp="$(mktemp -d)"
  curl -fsSL "https://codeload.github.com/${VPS_AI_REPO}/tar.gz/${ref}" | tar -xz -C "$tmp" \
    || { echo "FATAL: khong tai duoc ${VPS_AI_REPO}@${ref}" >&2; exit 1; }
  rm -rf "$src"
  mv "$tmp"/* "$src"
  rm -rf "$tmp"
  exec bash "${src}/install.sh" "$@"
fi

# shellcheck source=lib/common.sh
source "${SELF_DIR}/lib/common.sh"
# shellcheck source=lib/caddy.sh
source "${SELF_DIR}/lib/caddy.sh"

# ---- Args -------------------------------------------------------------------
WANT_HERMES=false
WANT_N8N=false
WANT_OPENCLAW=false
DOMAIN_ARG=""
MGMT_KEY_ARG=""
EMAIL_ARG=""
HERMES_DOMAIN_ARG=""
N8N_DOMAIN_ARG=""
OPENCLAW_DOMAIN_ARG=""
HERMES_REF="main"
HERMES_WITH_ZALO=true
HERMES_WITH_RAG=true
N8N_REF="main"
N8N_IPS=""

usage() { sed -n '3,33p' "${SELF_DIR}/install.sh" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --hermes)          WANT_HERMES=true; shift ;;
    --n8n)             WANT_N8N=true; shift ;;
    --openclaw)        WANT_OPENCLAW=true; shift ;;
    --all)             WANT_HERMES=true; WANT_N8N=true; WANT_OPENCLAW=true; shift ;;
    --domain)          DOMAIN_ARG="$2"; shift 2 ;;
    --mgmt-key)        MGMT_KEY_ARG="$2"; shift 2 ;;
    --email)           EMAIL_ARG="$2"; shift 2 ;;
    --hermes-domain)   HERMES_DOMAIN_ARG="$2"; shift 2 ;;
    --n8n-domain)      N8N_DOMAIN_ARG="$2"; shift 2 ;;
    --openclaw-domain) OPENCLAW_DOMAIN_ARG="$2"; shift 2 ;;
    --ref)             shift 2 ;;  # da xu ly o buoc tai source
    --hermes-ref)      HERMES_REF="$2"; shift 2 ;;
    --skip-zalo)       HERMES_WITH_ZALO=false; shift ;;
    --no-rag)          HERMES_WITH_RAG=false; shift ;;
    --n8n-ref)         N8N_REF="$2"; shift 2 ;;
    --ips)             N8N_IPS="$2"; shift 2 ;;
    -h|--help)         usage; exit 0 ;;
    *)                 echo "WARN: bo qua flag khong ro: $1" >&2; shift ;;
  esac
done

if [[ "$WANT_HERMES$WANT_N8N$WANT_OPENCLAW" == "falsefalsefalse" ]]; then
  usage
  echo ""
  echo "LOI: chon it nhat 1 app: --hermes, --n8n, --openclaw (hoac --all)" >&2
  exit 1
fi

log "=== vps-ai-management installer ${VPS_AI_VERSION} ==="
log "Apps: hermes=${WANT_HERMES} n8n=${WANT_N8N} openclaw=${WANT_OPENCLAW}"

# ---- 1. Pre-flight ------------------------------------------------------------
step "1. Kiem tra he thong"
preflight_checks
prepare_apt

# ---- 2. Domain + key dung chung ----------------------------------------------
step "2. Domain + management key"
resolve_server_ip
resolve_base_domain "$DOMAIN_ARG"
init_shared_env "$MGMT_KEY_ARG" "$EMAIL_ARG"

# Ten mien cho tung app: .env cua app (lan cai truoc) > --<app>-domain > tu tinh
HERMES_DOMAIN=""
N8N_DOMAIN=""
OPENCLAW_DOMAIN=""
$WANT_HERMES   && HERMES_DOMAIN="$(app_domain hermes "$HERMES_DOMAIN_ARG")"
$WANT_N8N      && N8N_DOMAIN="$(app_domain n8n "$N8N_DOMAIN_ARG")"
$WANT_OPENCLAW && OPENCLAW_DOMAIN="$(app_domain openclaw "$OPENCLAW_DOMAIN_ARG")"
for pair in "hermes:$HERMES_DOMAIN" "n8n:$N8N_DOMAIN" "openclaw:$OPENCLAW_DOMAIN"; do
  [[ -n "${pair#*:}" ]] && log "  ${pair%%:*} -> ${pair#*:}"
done

# ---- 3. Nen tang dung chung ---------------------------------------------------
step "3. Goi he thong + Node.js + Caddy + firewall"
install_base_packages
ensure_swap
fix_ipv6_preference
install_nodejs
install_caddy
setup_caddy_base
setup_firewall_base

# ---- 4. Cai tung app ------------------------------------------------------------
# Moi module chay trong 1 tien trinh bash rieng (khong dung subshell trong `if`
# vi bash tat errexit trong ngu canh dieu kien): loi o 1 app khong chan app khac.
FAILED_APPS=()
run_module() {
  local name="$1"
  step "4. Cai ${name}"
  if bash "${SELF_DIR}/lib/run-module.sh" "$name"; then
    log "${name}: cai dat xong"
    mark_installed "$name"
  else
    log "LOI: ${name} cai dat that bai — xem log phia tren"
    FAILED_APPS+=("$name")
  fi
}

export WANT_HERMES WANT_N8N WANT_OPENCLAW SELF_DIR SERVER_IP BASE_DOMAIN MGMT_API_KEY ACME_EMAIL MEM_TOTAL_MB \
       HERMES_DOMAIN N8N_DOMAIN OPENCLAW_DOMAIN \
       HERMES_REF HERMES_WITH_ZALO HERMES_WITH_RAG N8N_REF N8N_IPS
$WANT_OPENCLAW && run_module openclaw
$WANT_HERMES   && run_module hermes
$WANT_N8N      && run_module n8n

# ---- 5. Hoan tat ----------------------------------------------------------------
step "5. Hoan tat"
reload_caddy || FAILED_APPS+=(caddy)
install_cli
cleanup_apt
if [[ "${VPS_AI_LOG_REDIRECTED:-0}" == "1" ]]; then /usr/local/bin/vps-ai info; else /usr/local/bin/vps-ai info | tee -a "$LOG_FILE"; fi

if [[ ${#FAILED_APPS[@]} -gt 0 ]]; then
  log "CANH BAO: cac app cai loi: ${FAILED_APPS[*]} — chay lai install.sh voi flag tuong ung"
  exit 1
fi
log "=== vps-ai-management cai dat hoan tat ==="
