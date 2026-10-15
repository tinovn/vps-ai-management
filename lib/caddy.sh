#!/bin/bash
# =============================================================================
# lib/caddy.sh — 1 Caddy dung chung cho moi app
#
#   /etc/caddy/Caddyfile                 global options + import sites/*.caddy
#   /etc/vps-ai/caddy/sites/<app>.caddy  1 site file / app
#   /usr/local/sbin/vps-ai-caddy-env     gom DOMAIN/CADDY_TLS/... tu .env cua tung app
#                                        thanh bien co prefix (HERMES_DOMAIN, OPENCLAW_DOMAIN...)
#                                        -> /run/vps-ai/caddy.env, chay truoc moi start/reload
#
# Nho vay management API cua Hermes / OpenClaw van sua DOMAIN trong .env rieng
# cua minh roi `systemctl restart caddy` nhu cu ma khong de len nhau.
# =============================================================================

readonly CADDY_FALLBACK_VERSION="2.10.2"
readonly CADDY_ENV_FILE="/run/vps-ai/caddy.env"

install_caddy() {
  if command -v caddy &>/dev/null; then
    log "Caddy: $(caddy version | head -1)"
    return 0
  fi
  local arch version deb
  arch="$(dpkg --print-architecture)"
  version="$(curl -fsSL https://api.github.com/repos/caddyserver/caddy/releases/latest 2>/dev/null \
    | grep -oE '"tag_name": *"v[^"]+"' | grep -oE '[0-9][^"]*' || true)"
  version="${version:-$CADDY_FALLBACK_VERSION}"
  deb="/tmp/caddy_${version}_linux_${arch}.deb"
  if curl -fsSL -o "$deb" \
      "https://github.com/caddyserver/caddy/releases/download/v${version}/caddy_${version}_linux_${arch}.deb"; then
    apt_install "$deb"
    rm -f "$deb"
  else
    log "WARN: tai Caddy .deb that bai — dung goi caddy cua Ubuntu"
    apt_install caddy
  fi
  log "Caddy: $(caddy version | head -1)"
}

setup_caddy_base() {
  mkdir -p "$CADDY_SITES_DIR" /var/log/caddy
  chown caddy:caddy /var/log/caddy 2>/dev/null || true

  install -m 0755 "${SELF_DIR}/bin/vps-ai-caddy-env" /usr/local/sbin/vps-ai-caddy-env
  install -m 0644 "${SELF_DIR}/caddy/Caddyfile" /etc/caddy/Caddyfile

  # Override cua repo goc (Hermes/OpenClaw tro thang toi Caddyfile rieng) duoc thay
  # bang override dung chung. ExecStartPre/ExecReload chay bang root ('+') de doc
  # duoc cac .env chmod 600; EnvironmentFile duoc systemd nap lai cho tung lenh.
  mkdir -p /etc/systemd/system/caddy.service.d
  cat > /etc/systemd/system/caddy.service.d/override.conf <<EOF
# Managed by vps-ai-management — do not edit
[Service]
ExecStartPre=+/usr/local/sbin/vps-ai-caddy-env
EnvironmentFile=-${CADDY_ENV_FILE}
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/Caddyfile --adapter caddyfile
ExecReload=
ExecReload=+/usr/local/sbin/vps-ai-caddy-env
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile --force
EOF
  systemctl daemon-reload
  systemctl enable caddy >/dev/null 2>&1
  log "Caddy: dung chung /etc/caddy/Caddyfile + ${CADDY_SITES_DIR}/*.caddy"
}

# install_site <app> — copy caddy/sites/<app>.caddy (template dung bien moi truong)
install_site() {
  local app="$1"
  install -m 0644 "${SELF_DIR}/caddy/sites/${app}.caddy" "${CADDY_SITES_DIR}/${app}.caddy"
}

# Validate truoc, roi restart (restart chac chan nap override + env moi)
reload_caddy() {
  /usr/local/sbin/vps-ai-caddy-env
  if ! ( set -a; . "$CADDY_ENV_FILE"; caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile ) >>"$LOG_FILE" 2>&1; then
    log "LOI: Caddyfile khong hop le — xem ${LOG_FILE}; Caddy giu cau hinh cu"
    return 1
  fi
  systemctl restart caddy
  sleep 2
  if systemctl is-active --quiet caddy; then
    log "Caddy dang chay"
  else
    log "LOI: Caddy khong start duoc — journalctl -u caddy -n 50"
    return 1
  fi
}
