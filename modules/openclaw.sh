#!/bin/bash
# =============================================================================
# modules/openclaw.sh — OpenClaw gateway (npm global) + management API (:9998)
# Port tu tinovn/vps-openclaw-management/install.sh. Khac biet so voi ban goc:
#   - Node.js / Caddy / UFW do lib/ dung chung lo
#   - Caddy site: /etc/vps-ai/caddy/sites/openclaw.caddy (doc DOMAIN/CADDY_TLS tu /opt/openclaw/.env)
#   - Chay lai khong rotate gateway token
#   - NODE_OPTIONS heap = 80% RAM chia cho so app tren VPS
# Bien vao: OPENCLAW_DOMAIN, MGMT_API_KEY
# =============================================================================

readonly OPENCLAW_REPO_RAW="https://raw.githubusercontent.com/tinovn/vps-openclaw-management/main"
readonly OPENCLAW_DIR="/opt/openclaw"
readonly OPENCLAW_MGMT_DIR="/opt/openclaw-mgmt"
readonly OPENCLAW_ENV="${OPENCLAW_DIR}/.env"
readonly OPENCLAW_TEMPLATES_DIR="/etc/openclaw/config"
readonly OPENCLAW_GATEWAY_PORT=18789

install_openclaw() {
  log "Cai OpenClaw (npm)"
  npm install -g openclaw@latest >>"$LOG_FILE" 2>&1 || die "npm install -g openclaw loi"
  log "OpenClaw: $(openclaw --version 2>/dev/null || echo unknown)"

  openclaw_install_chrome
  openclaw_layout
  openclaw_write_env
  openclaw_seed_config
  openclaw_write_units
  install_site openclaw
  ufw_allow "${OPENCLAW_MGMT_PORT}/tcp" openclaw-mgmt

  systemctl enable openclaw >/dev/null 2>&1
  systemctl restart openclaw
  if wait_http "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/healthz" 24 5; then
    log "OpenClaw gateway san sang"
  else
    log "WARN: OpenClaw gateway chua tra /healthz sau 120s"
  fi

  # Khoi tao auth store (SQLite). OpenClaw >= 2026.9: doctor can giu rieng state DB
  systemctl stop openclaw
  HOME="$OPENCLAW_DIR" "$(command -v openclaw)" doctor --fix --yes --non-interactive >>"$LOG_FILE" 2>&1 \
    || log "WARN: openclaw doctor --fix chua chay duoc (se chay lai khi cau hinh provider)"
  systemctl start openclaw

  openclaw_install_mgmt_api
}

# Chrome headless cho browser tool — chi co ban amd64
openclaw_install_chrome() {
  if command -v google-chrome &>/dev/null; then
    return 0
  fi
  if [[ "$(dpkg --print-architecture)" != "amd64" ]]; then
    log "WARN: Google Chrome chi co ban amd64 — bo qua (browser tool cua OpenClaw se khong dung duoc)"
    return 0
  fi
  log "Cai Google Chrome (headless browser)"
  curl -fsSL https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -o /tmp/chrome.deb \
    && apt_install /tmp/chrome.deb \
    || log "WARN: cai Google Chrome loi"
  rm -f /tmp/chrome.deb
}

# OpenClaw >= 2026.9.1 tu choi atomic-replace neu thu muc cha la symlink:
# .openclaw phai la thu muc that, config la symlink tro toi no.
openclaw_layout() {
  mkdir -p "${OPENCLAW_DIR}/data" "$OPENCLAW_MGMT_DIR" "$OPENCLAW_TEMPLATES_DIR"
  if [[ -L "${OPENCLAW_DIR}/.openclaw" ]]; then
    local old
    old="$(readlink -f "${OPENCLAW_DIR}/.openclaw")"
    rm -f "${OPENCLAW_DIR}/.openclaw"
    [[ -d "$old" && "$old" != "${OPENCLAW_DIR}/.openclaw" ]] && mv "$old" "${OPENCLAW_DIR}/.openclaw"
  fi
  mkdir -p "${OPENCLAW_DIR}/.openclaw"
  if [[ ! -L "${OPENCLAW_DIR}/config" ]]; then
    if [[ -d "${OPENCLAW_DIR}/config" ]]; then
      cp -an "${OPENCLAW_DIR}/config/." "${OPENCLAW_DIR}/.openclaw/" 2>/dev/null || true
      rm -rf "${OPENCLAW_DIR}/config"
    fi
    ln -sfn "${OPENCLAW_DIR}/.openclaw" "${OPENCLAW_DIR}/config"
  fi
  mkdir -p "${OPENCLAW_DIR}/config/agents/main/agent" "${OPENCLAW_DIR}/config/agents/main/sessions"
}

openclaw_write_env() {
  local caddy_tls="" heap apps
  if ! dns_points_here "$OPENCLAW_DOMAIN"; then
    caddy_tls="tls internal"
    log "WARN: DNS ${OPENCLAW_DOMAIN} chua tro ve ${SERVER_IP} — OpenClaw dung chung chi tu ky (PUT /api/domain sau khi tro DNS)"
  fi
  apps="$(total_app_count)"
  heap=$(( MEM_TOTAL_MB * 80 / 100 / (apps > 0 ? apps : 1) ))

  if [[ ! -f "$OPENCLAW_ENV" ]]; then
    cat > "$OPENCLAW_ENV" <<EOF
# OpenClaw Environment — written by vps-ai-management $(date -u +%FT%TZ)
# Sau khi thay doi: systemctl restart openclaw caddy

OPENCLAW_VERSION=latest

# Gateway
OPENCLAW_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}
OPENCLAW_GATEWAY_TOKEN=$(openssl rand -hex 32)

# Domain & TLS (Caddy site: /etc/vps-ai/caddy/sites/openclaw.caddy)
DOMAIN=${OPENCLAW_DOMAIN}
CADDY_TLS=${caddy_tls}

# Management API
OPENCLAW_MGMT_API_KEY=${MGMT_API_KEY}

# Node.js heap (80% RAM / ${apps} app)
NODE_OPTIONS=--max-old-space-size=${heap}

# AI Provider API Keys (uncomment va dien)
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# GEMINI_API_KEY=
# OPENROUTER_API_KEY=

# Messaging Channels
# TELEGRAM_BOT_TOKEN=
# ZALO_BOT_TOKEN=
EOF
    chmod 600 "$OPENCLAW_ENV"
    log "Ghi ${OPENCLAW_ENV} (moi)"
  else
    log "Giu ${OPENCLAW_ENV} (khong rotate gateway token)"
    upsert_env "$OPENCLAW_ENV" OPENCLAW_MGMT_API_KEY "$MGMT_API_KEY"
    [[ -n "$(read_env_value "$OPENCLAW_ENV" OPENCLAW_GATEWAY_TOKEN)" ]] \
      || upsert_env "$OPENCLAW_ENV" OPENCLAW_GATEWAY_TOKEN "$(openssl rand -hex 32)"
    [[ -n "$(existing_app_domain openclaw)" ]] || upsert_env "$OPENCLAW_ENV" DOMAIN "$OPENCLAW_DOMAIN"
  fi
}

openclaw_seed_config() {
  local provider
  for provider in anthropic openai google openai-codex deepseek groq together mistral xai cerebras \
                  sambanova fireworks cohere yi baichuan stepfun siliconflow novita openrouter \
                  minimax moonshot zhipu; do
    curl -fsSL "${OPENCLAW_REPO_RAW}/config/${provider}.json" -o "${OPENCLAW_TEMPLATES_DIR}/${provider}.json" 2>/dev/null \
      || log "WARN: khong tai duoc template ${provider}.json"
  done

  local cfg="${OPENCLAW_DIR}/config/openclaw.json"
  if [[ -f "$cfg" ]]; then
    log "Giu ${cfg}, chi cap nhat allowedOrigins"
  else
    [[ -f "${OPENCLAW_TEMPLATES_DIR}/anthropic.json" ]] || die "Thieu template anthropic.json"
    jq '.plugins = { "entries": { "zalo": { "enabled": true }, "bonjour": { "enabled": false } } }' \
      "${OPENCLAW_TEMPLATES_DIR}/anthropic.json" > "$cfg"
  fi

  local token domain
  token="$(read_env_value "$OPENCLAW_ENV" OPENCLAW_GATEWAY_TOKEN)"
  domain="$(read_env_value "$OPENCLAW_ENV" DOMAIN | sed -E 's#^https?://##')"
  jq --arg token "$token" --arg domain "$domain" '
    .gateway.auth.token = $token |
    .gateway.controlUi.allowedOrigins = (
      ((.gateway.controlUi.allowedOrigins // []) +
        (if $domain != "" then ["https://\($domain)", "http://\($domain)"] else [] end) +
        ["http://localhost", "http://127.0.0.1"]) | unique
    )
  ' "$cfg" > "${cfg}.tmp" && mv "${cfg}.tmp" "$cfg"
}

openclaw_write_units() {
  cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${OPENCLAW_DIR}
EnvironmentFile=${OPENCLAW_ENV}
Environment=HOME=${OPENCLAW_DIR}
Environment=NODE_ENV=production
Environment=OPENCLAW_GATEWAY_BIND=lan
ExecStart=$(command -v openclaw) gateway --port ${OPENCLAW_GATEWAY_PORT} --allow-unconfigured
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

openclaw_install_mgmt_api() {
  log "Cai OpenClaw management API (:${OPENCLAW_MGMT_PORT})"
  local i
  for i in 1 2 3; do
    curl -fsSL --retry 2 "${OPENCLAW_REPO_RAW}/management-api/server.js" -o "${OPENCLAW_MGMT_DIR}/server.js" && break
    log "WARN: lan ${i} tai server.js loi, thu lai..."
    sleep 3
  done
  [[ -f "${OPENCLAW_MGMT_DIR}/server.js" ]] || die "Khong tai duoc management-api/server.js"
  curl -fsSL --retry 2 "${OPENCLAW_REPO_RAW}/version.json" -o "${OPENCLAW_MGMT_DIR}/version.json" \
    || log "WARN: khong tai duoc version.json"
  # server.js doc/ghi /opt/openclaw/Caddyfile (legacy) — giu 1 ban de API khong loi;
  # Caddy thuc te dung /etc/vps-ai/caddy/sites/openclaw.caddy
  [[ -f "${OPENCLAW_DIR}/Caddyfile" ]] || cp "${SELF_DIR}/caddy/sites/openclaw.caddy" "${OPENCLAW_DIR}/Caddyfile"

  cat > /etc/systemd/system/openclaw-mgmt.service <<EOF
[Unit]
Description=OpenClaw Management API
After=network-online.target openclaw.service
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${OPENCLAW_MGMT_DIR}
ExecStart=$(command -v node) ${OPENCLAW_MGMT_DIR}/server.js
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable openclaw-mgmt >/dev/null 2>&1
  systemctl restart openclaw-mgmt
  if wait_http "http://127.0.0.1:${OPENCLAW_MGMT_PORT}/login" 12 5; then
    log "openclaw-mgmt dang chay"
  else
    log "WARN: openclaw-mgmt chua phan hoi — journalctl -u openclaw-mgmt"
  fi
}
