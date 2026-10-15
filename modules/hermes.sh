#!/bin/bash
# =============================================================================
# modules/hermes.sh — Hermes Agent + management API (+ RAG MCP, Zalo plugin)
# Port tu tinovn/vps-hermes-management/install.sh. Khac biet so voi ban goc:
#   - Node.js / Caddy / UFW / swap do lib/common.sh + lib/caddy.sh lo (dung chung)
#   - RAG MCP chay o :9996 (ban goc :9998 trung voi OpenClaw management API)
#   - Caddy site: /etc/vps-ai/caddy/sites/hermes.caddy thay vi /opt/hermes/Caddyfile
# Bien vao: HERMES_DOMAIN, MGMT_API_KEY, HERMES_REF, HERMES_WITH_ZALO, HERMES_WITH_RAG
# =============================================================================

readonly HERMES_REPO_RAW="https://raw.githubusercontent.com/tinovn/vps-hermes-management/main"
readonly HERMES_INSTALL_DIR="/opt/hermes"
readonly HERMES_SRC_DIR="${HERMES_INSTALL_DIR}/hermes-agent"
readonly HERMES_MGMT_DIR="/opt/hermes-mgmt"
readonly HERMES_RAG_DIR="/opt/hermes-rag"
readonly HERMES_TEMPLATES_DIR="/etc/hermes/config"
readonly HERMES_ENV="${HERMES_INSTALL_DIR}/.env"
readonly HERMES_DASHBOARD_PORT=9119
readonly HERMES_RAG_PORT=9996
readonly HERMES_RAG_EMBED_MODEL_DEFAULT="sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2"
readonly HERMES_PM_EXTRAS="messaging voice"
readonly HERMES_LAUNCHER="${HERMES_SRC_DIR}/.hermes/bin/hermes"
readonly HERMES_INSTALLER_URL="https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh"
readonly HERMES_PYTHON_PIN="3.11"
readonly HERMES_ZALO_PLUGIN_REPO="https://github.com/tinovn/hermes-zalo-plugin"
readonly HERMES_ZALO_PLUGIN_NAME="zalo-personal"

# Python inline dung venv cua mgmt-api (co pyyaml) de sua /root/.hermes/config.yaml
hermes_yaml() {
  HERMES_HOME=/root/.hermes "${HERMES_MGMT_DIR}/.venv/bin/python" -
}

install_hermes() {
  hermes_install_uv
  mkdir -p "${HERMES_INSTALL_DIR}/.hermes" "${HERMES_INSTALL_DIR}/data" \
           "${HERMES_MGMT_DIR}" "${HERMES_TEMPLATES_DIR}/channels"
  [[ "$HERMES_WITH_RAG" == "true" ]] && mkdir -p "${HERMES_RAG_DIR}/data" "${HERMES_RAG_DIR}/docs"

  hermes_install_agent
  hermes_install_mgmt_api
  hermes_install_zalo
  hermes_write_env
  [[ "$HERMES_WITH_RAG" == "true" ]] && hermes_install_rag
  hermes_seed_templates
  hermes_write_units
  install_site hermes
  ufw_allow "${HERMES_MGMT_PORT}/tcp" hermes-mgmt

  systemctl enable hermes.target hermes-gateway.service hermes-dashboard.service hermes-mgmt.service >/dev/null 2>&1
  systemctl restart hermes-mgmt.service
  if [[ "$HERMES_WITH_RAG" == "true" ]]; then
    systemctl enable hermes-rag.service >/dev/null 2>&1
    systemctl restart hermes-rag.service || log "WARN: hermes-rag start loi (journalctl -u hermes-rag)"
  fi
  systemctl restart hermes-dashboard.service || log "WARN: hermes-dashboard start loi (chua cau hinh model?)"
  systemctl restart hermes-gateway.service   || log "WARN: hermes-gateway start loi (chua cau hinh kenh?)"

  if wait_http "http://127.0.0.1:${HERMES_MGMT_PORT}/health" 18 5; then
    log "hermes-mgmt healthy"
  else
    log "WARN: hermes-mgmt chua tra /health sau 90s — journalctl -u hermes-mgmt"
  fi
}

hermes_install_uv() {
  if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh >>"$LOG_FILE" 2>&1
    ln -sf /root/.local/bin/uv /usr/local/bin/uv
  fi
  uv python install "$HERMES_PYTHON_PIN" >>"$LOG_FILE" 2>&1
  log "uv: $(uv --version)"
}

# Giao cho installer upstream (Python 3.14 + Node rieng trong /root/.hermes/tools,
# tu build web_dist + TUI). --non-interactive bo wizard va `hermes gateway install`.
hermes_install_agent() {
  log "Cai Hermes Agent (ref=${HERMES_REF})"
  # Build web UI (Vite) can >1GB RAM — dung service cu de tranh OOM khi cai lai
  systemctl stop hermes-gateway.service hermes-dashboard.service 2>/dev/null || true

  local args=(--non-interactive --skip-browser --skip-computer-use
              --dir "${HERMES_SRC_DIR}" --hermes-home /root/.hermes)
  if [[ "$HERMES_REF" =~ ^[0-9a-f]{7,40}$ ]]; then
    args+=(--commit "$HERMES_REF")
  else
    args+=(--branch "$HERMES_REF")
  fi
  rm -rf "${HERMES_SRC_DIR}/.venv"
  curl -fsSL "$HERMES_INSTALLER_URL" -o /tmp/hermes-upstream-install.sh \
    || die "Khong tai duoc installer upstream cua Hermes"
  bash /tmp/hermes-upstream-install.sh "${args[@]}" </dev/null >>"$LOG_FILE" 2>&1 \
    || die "Installer upstream Hermes loi — xem ${LOG_FILE} va /root/.hermes/logs/install.log"
  [[ -x "$HERMES_LAUNCHER" ]] || die "Khong thay launcher Hermes tai ${HERMES_LAUNCHER}"
  ln -sf "$HERMES_LAUNCHER" /usr/local/bin/hermes

  local extra_args=() e
  for e in $HERMES_PM_EXTRAS; do extra_args+=(--extra "$e"); done
  (cd "$HERMES_SRC_DIR" && /usr/local/bin/hermes pm install "${extra_args[@]}") >>"$LOG_FILE" 2>&1 \
    || log "WARN: 'hermes pm install ${extra_args[*]}' loi — Hermes se lazy-install khi dung"
  log "Hermes: $(/usr/local/bin/hermes --version 2>/dev/null | head -1 || echo installed)"
}

hermes_install_mgmt_api() {
  log "Cai Hermes management API"
  local f
  for f in pyproject.toml \
           hermes_mgmt/__init__.py hermes_mgmt/main.py hermes_mgmt/config.py \
           hermes_mgmt/auth.py hermes_mgmt/deps.py hermes_mgmt/models.py \
           hermes_mgmt/env_file.py hermes_mgmt/systemd_ctl.py \
           hermes_mgmt/cli_runner.py hermes_mgmt/hermes_fs.py \
           hermes_mgmt/routes/__init__.py hermes_mgmt/routes/status.py \
           hermes_mgmt/routes/control.py hermes_mgmt/routes/config_routes.py \
           hermes_mgmt/routes/channels.py hermes_mgmt/routes/cron_routes.py \
           hermes_mgmt/routes/logs.py hermes_mgmt/routes/auth_routes.py \
           hermes_mgmt/routes/env_routes.py hermes_mgmt/routes/cli_routes.py \
           hermes_mgmt/routes/zalo.py hermes_mgmt/routes/openviking.py \
           hermes_mgmt/routes/whatsapp.py hermes_mgmt/assets/whatsapp_pair.mjs \
           hermes_mgmt/routes/codex.py hermes_mgmt/routes/roles.py \
           hermes_mgmt/routes/maintenance.py hermes_mgmt/routes/insights.py; do
    mkdir -p "$(dirname "${HERMES_MGMT_DIR}/${f}")"
    curl -fsSL "${HERMES_REPO_RAW}/management-api/${f}" -o "${HERMES_MGMT_DIR}/${f}" \
      || die "Khong tai duoc management-api/${f}"
  done

  # config/roles + config/rules: lay danh sach dong qua GitHub contents API
  local sub names n
  for sub in rules roles; do
    mkdir -p "${HERMES_MGMT_DIR}/config/${sub}"
    names=$(curl -fsSL "https://api.github.com/repos/tinovn/vps-hermes-management/contents/config/${sub}" 2>/dev/null \
      | grep -oE '"name": *"[^"]+"' | sed -E 's/"name": *"([^"]+)"/\1/' || true)
    if [[ -z "$names" ]]; then
      log "WARN: khong liet ke duoc config/${sub} qua GitHub API"
      continue
    fi
    for n in $names; do
      curl -fsSL "${HERMES_REPO_RAW}/config/${sub}/${n}" -o "${HERMES_MGMT_DIR}/config/${sub}/${n}" \
        || log "WARN: khong tai duoc config/${sub}/${n}"
    done
  done

  [[ -d "${HERMES_MGMT_DIR}/.venv" ]] || uv venv --python "$HERMES_PYTHON_PIN" "${HERMES_MGMT_DIR}/.venv" >>"$LOG_FILE" 2>&1
  VIRTUAL_ENV="${HERMES_MGMT_DIR}/.venv" uv pip install --python "${HERMES_MGMT_DIR}/.venv/bin/python" \
    -e "${HERMES_MGMT_DIR}" >>"$LOG_FILE" 2>&1

  # Tat boilerplate "Cronjob Response: ..." cua cron (nguoi dung chi thay noi dung)
  mkdir -p /root/.hermes
  hermes_yaml <<'PYEOF' >>"$LOG_FILE" 2>&1 || log "WARN: khong set duoc cron.wrap_response=false"
import os, yaml
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
d = (yaml.safe_load(open(p)) or {}) if os.path.exists(p) else {}
c = d.get("cron") if isinstance(d.get("cron"), dict) else {}
c["wrap_response"] = False
d["cron"] = c
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PYEOF
}

hermes_install_zalo() {
  if [[ "$HERMES_WITH_ZALO" != "true" ]]; then
    log "Bo qua plugin Zalo (--skip-zalo)"
    return 0
  fi
  log "Cai plugin Zalo ca nhan"
  local dir="/root/.hermes/plugins/${HERMES_ZALO_PLUGIN_NAME}" plugin_id
  mkdir -p "$(dirname "$dir")"
  if [[ ! -d "${dir}/.git" ]]; then
    rm -rf "$dir"
    git clone --depth 1 "$HERMES_ZALO_PLUGIN_REPO" "$dir" >>"$LOG_FILE" 2>&1 \
      || { log "WARN: clone plugin Zalo loi — bo qua"; return 0; }
  else
    git -C "$dir" pull --ff-only >>"$LOG_FILE" 2>&1 || true
  fi
  if [[ ! -f "${dir}/sidecar/package.json" ]]; then
    log "WARN: source plugin Zalo thieu sidecar — bo qua"
    return 0
  fi
  (cd "${dir}/sidecar" && npm install --no-audit --no-fund --loglevel=error) >>"$LOG_FILE" 2>&1 \
    || log "WARN: npm install sidecar Zalo loi — chay tay truoc khi dung"
  mkdir -p /opt/data/zalo

  # Plugin phang: registry key = truong name: trong plugin.yaml
  plugin_id="$(grep -E '^name:' "${dir}/plugin.yaml" 2>/dev/null | head -1 | cut -d: -f2 | xargs || true)"
  plugin_id="${plugin_id:-$HERMES_ZALO_PLUGIN_NAME}"
  HERMES_HOME=/root/.hermes /usr/local/bin/hermes plugins enable "$plugin_id" >>"$LOG_FILE" 2>&1 \
    || log "WARN: 'hermes plugins enable ${plugin_id}' loi"
  # Enable plugin chi nap adapter; gateway chi start platform khi platforms.<id>.enabled=true
  hermes_yaml <<'PYEOF' >>"$LOG_FILE" 2>&1 || log "WARN: khong bat duoc platforms.zalo-personal.enabled"
import os, yaml
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
d = yaml.safe_load(open(p)) or {}
pl = d.get("platforms") if isinstance(d.get("platforms"), dict) else {}
e = pl.get("zalo-personal") if isinstance(pl.get("zalo-personal"), dict) else {}
e["enabled"] = True
pl["zalo-personal"] = e
d["platforms"] = pl
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PYEOF
}

# .env: giu nguyen moi token da co; MGMT key luon dong bo voi key dung chung
hermes_write_env() {
  local caddy_tls=""
  if ! dns_points_here "$HERMES_DOMAIN"; then
    caddy_tls="tls internal"
    log "WARN: DNS ${HERMES_DOMAIN} chua tro ve ${SERVER_IP} — Hermes dung chung chi tu ky (doi domain qua mgmt API sau)"
  fi

  if [[ ! -f "$HERMES_ENV" ]]; then
    cat > "$HERMES_ENV" <<EOF
# hermes-vps environment — written by vps-ai-management $(date -u +%FT%TZ)
# After changes: systemctl restart hermes-gateway hermes-dashboard hermes-mgmt caddy

# --- Core ---
HERMES_HOME=/root/.hermes
HERMES_VPS_VERSION=vps-ai-${VPS_AI_VERSION}
HERMES_DROPLET_IP=${SERVER_IP}
DOMAIN=${HERMES_DOMAIN}
CADDY_TLS=${caddy_tls}

# --- Ports ---
HERMES_DASHBOARD_PORT=${HERMES_DASHBOARD_PORT}
HERMES_MGMT_PORT=${HERMES_MGMT_PORT}

# --- RAG MCP service (127.0.0.1:${HERMES_RAG_PORT}/mcp) ---
RAG_PORT=${HERMES_RAG_PORT}
RAG_EMBED_MODEL=${HERMES_RAG_EMBED_MODEL_DEFAULT}
RAG_DATA_DIR=${HERMES_RAG_DIR}/data
RAG_DOCS_DIR=${HERMES_RAG_DIR}/docs

# --- Auth ---
HERMES_GATEWAY_TOKEN=$(openssl rand -hex 32)
HERMES_MGMT_API_KEY=${MGMT_API_KEY}
HERMES_MGMT_SESSION_SECRET=$(openssl rand -hex 32)
HERMES_AUTH_TOKEN=$(openssl rand -hex 24)

# --- Provider API keys (fill what you use) ---
# OPENAI_API_KEY=
# ANTHROPIC_API_KEY=
# OPENROUTER_API_KEY=

# --- Messaging platform tokens (fill what you use) ---
# TELEGRAM_BOT_TOKEN=
# DISCORD_BOT_TOKEN=
EOF
    chmod 600 "$HERMES_ENV"
    log "Ghi ${HERMES_ENV} (moi)"
  else
    log "Giu ${HERMES_ENV}, bo sung key con thieu"
    local k
    for k in HERMES_GATEWAY_TOKEN HERMES_MGMT_SESSION_SECRET; do
      [[ -n "$(read_env_value "$HERMES_ENV" "$k")" ]] || upsert_env "$HERMES_ENV" "$k" "$(openssl rand -hex 32)"
    done
    [[ -n "$(read_env_value "$HERMES_ENV" HERMES_AUTH_TOKEN)" ]] || upsert_env "$HERMES_ENV" HERMES_AUTH_TOKEN "$(openssl rand -hex 24)"
    [[ -n "$(read_env_value "$HERMES_ENV" HERMES_HOME)" ]] || upsert_env "$HERMES_ENV" HERMES_HOME /root/.hermes
    [[ -n "$(read_env_value "$HERMES_ENV" DOMAIN)" ]] || upsert_env "$HERMES_ENV" DOMAIN "$HERMES_DOMAIN"
    upsert_env "$HERMES_ENV" HERMES_MGMT_API_KEY "$MGMT_API_KEY"
    # RAG o :9998 (ban goc) se trung OpenClaw mgmt -> chuyen sang :9996
    [[ "$(read_env_value "$HERMES_ENV" RAG_PORT)" == "9998" || -z "$(read_env_value "$HERMES_ENV" RAG_PORT)" ]] \
      && upsert_env "$HERMES_ENV" RAG_PORT "$HERMES_RAG_PORT"
  fi

  if [[ "$HERMES_WITH_ZALO" == "true" ]] && ! grep -q '^ZALO_PERSONAL_OWNER_UID=' "$HERMES_ENV"; then
    cat >> "$HERMES_ENV" <<'EOF'

# --- Zalo personal plugin (zalo-personal) ---
# Unofficial Zalo Web API via zca-js. USE A SECONDARY NUMBER (ban risk).
# First run QR login: curl -X POST http://127.0.0.1:3838/login/qr ; open /qr.png
ZALO_PERSONAL_OWNER_UID=
ZALO_PERSONAL_SIDECAR_PORT=3838
ZALO_PERSONAL_SESSION_DIR=/opt/data/zalo
ZALO_PERSONAL_ALLOW_ALL_USERS=true
# ZALO_PERSONAL_ALLOWED_USERS=
# ZALO_OWNER_NICKNAME=sếp
EOF
  fi
}

hermes_install_rag() {
  log "Cai RAG MCP service (:${HERMES_RAG_PORT})"
  local f model cache
  if [[ ! -f "${HERMES_RAG_DIR}/pyproject.toml" ]]; then
    for f in pyproject.toml README.md \
             hermes_rag/__init__.py hermes_rag/config.py hermes_rag/chunker.py \
             hermes_rag/embedder.py hermes_rag/store.py hermes_rag/ingest.py \
             hermes_rag/search.py hermes_rag/mcp_server.py hermes_rag/cli.py; do
      mkdir -p "$(dirname "${HERMES_RAG_DIR}/${f}")"
      curl -fsSL "${HERMES_REPO_RAW}/rag-mcp/${f}" -o "${HERMES_RAG_DIR}/${f}" \
        || die "Khong tai duoc rag-mcp/${f}"
    done
  fi
  [[ -d "${HERMES_RAG_DIR}/.venv" ]] || uv venv --python "$HERMES_PYTHON_PIN" "${HERMES_RAG_DIR}/.venv" >>"$LOG_FILE" 2>&1
  VIRTUAL_ENV="${HERMES_RAG_DIR}/.venv" uv pip install --python "${HERMES_RAG_DIR}/.venv/bin/python" \
    -e "${HERMES_RAG_DIR}" >>"$LOG_FILE" 2>&1
  ln -sf "${HERMES_RAG_DIR}/.venv/bin/hermes-rag" /usr/local/bin/hermes-rag

  model="$(read_env_value "$HERMES_ENV" RAG_EMBED_MODEL)"; model="${model:-$HERMES_RAG_EMBED_MODEL_DEFAULT}"
  cache="$(read_env_value "$HERMES_ENV" RAG_MODEL_CACHE)"; cache="${cache:-${HERMES_RAG_DIR}/models}"
  mkdir -p "$cache"
  log "Tai truoc embedding model ${model}"
  RAG_EMBED_MODEL="$model" RAG_MODEL_CACHE="$cache" "${HERMES_RAG_DIR}/.venv/bin/python" -c \
    "from hermes_rag.embedder import build_embedder; build_embedder('${model}', False, cache_dir='${cache}')" \
    >>"$LOG_FILE" 2>&1 || log "WARN: tai model loi (se thu lai khi service start)"

  RAG_MCP_PORT="$(read_env_value "$HERMES_ENV" RAG_PORT)" hermes_yaml <<'PYEOF' >>"$LOG_FILE" 2>&1 || log "WARN: khong dang ky duoc RAG MCP"
import os, yaml
p = os.path.join(os.environ["HERMES_HOME"], "config.yaml")
d = (yaml.safe_load(open(p)) or {}) if os.path.exists(p) else {}
d.setdefault("mcp_servers", {})["rag"] = {
    "url": f"http://127.0.0.1:{os.environ['RAG_MCP_PORT']}/mcp",
    "timeout": 180,
    "connect_timeout": 30,
}
yaml.safe_dump(d, open(p, "w"), allow_unicode=True, sort_keys=False)
PYEOF
}

hermes_seed_templates() {
  local tpl ch
  for tpl in anthropic openai google xai deepseek groq mistral together \
             nous-portal openrouter huggingface kimi mimo minimax zai openai-codex; do
    curl -fsSL "${HERMES_REPO_RAW}/config/${tpl}.json" -o "${HERMES_TEMPLATES_DIR}/${tpl}.json" 2>/dev/null \
      || log "WARN: template ${tpl}.json khong tai duoc"
  done
  for ch in telegram discord slack signal whatsapp email; do
    curl -fsSL "${HERMES_REPO_RAW}/config/channels/${ch}.json" -o "${HERMES_TEMPLATES_DIR}/channels/${ch}.json" 2>/dev/null \
      || true
  done
}

hermes_write_units() {
  cat > /etc/systemd/system/hermes.target <<'EOF'
[Unit]
Description=Hermes Agent target (gateway + dashboard + management API)
Wants=hermes-gateway.service hermes-dashboard.service hermes-mgmt.service
After=network-online.target

[Install]
WantedBy=multi-user.target
EOF

  # HOME de trong: systemd mac dinh /root cho User=root, khop voi `hermes gateway setup`
  cat > /etc/systemd/system/hermes-gateway.service <<EOF
[Unit]
Description=Hermes Agent — Messaging Gateway
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${HERMES_INSTALL_DIR}
EnvironmentFile=${HERMES_ENV}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/local/bin/hermes gateway run
Restart=always
RestartSec=5
MemoryMax=1536M

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/hermes-dashboard.service <<EOF
[Unit]
Description=Hermes Agent — Web Dashboard
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${HERMES_INSTALL_DIR}
EnvironmentFile=${HERMES_ENV}
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/local/bin/hermes dashboard --no-open --host 127.0.0.1 --port ${HERMES_DASHBOARD_PORT}
Restart=always
RestartSec=5
MemoryMax=1024M

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/hermes-mgmt.service <<EOF
[Unit]
Description=Hermes VPS Management API
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${HERMES_MGMT_DIR}
EnvironmentFile=${HERMES_ENV}
Environment=PYTHONUNBUFFERED=1
Environment=HERMES_INSTALL_DIR=${HERMES_INSTALL_DIR}
Environment=HERMES_TEMPLATES_DIR=${HERMES_TEMPLATES_DIR}
ExecStart=${HERMES_MGMT_DIR}/.venv/bin/uvicorn hermes_mgmt.main:app --host 0.0.0.0 --port ${HERMES_MGMT_PORT} --workers 1
Restart=always
RestartSec=10
MemoryMax=512M

[Install]
WantedBy=multi-user.target
EOF

  if [[ "$HERMES_WITH_RAG" == "true" ]]; then
    cat > /etc/systemd/system/hermes-rag.service <<EOF
[Unit]
Description=Hermes Agent — RAG MCP service
After=network-online.target
Wants=network-online.target
PartOf=hermes.target

[Service]
Type=simple
User=root
WorkingDirectory=${HERMES_RAG_DIR}
EnvironmentFile=${HERMES_ENV}
Environment=PYTHONUNBUFFERED=1
ExecStart=${HERMES_RAG_DIR}/.venv/bin/hermes-rag serve
Restart=always
RestartSec=10
MemoryMax=1536M

[Install]
WantedBy=hermes.target
EOF
  fi
  systemctl daemon-reload
}
