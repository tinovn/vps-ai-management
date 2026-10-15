#!/bin/bash
# =============================================================================
# modules/n8n.sh — n8n-agent (NestJS, :7071) + n8n stack (Docker: n8n, worker,
# postgres, redis, nocodb) qua POST /api/n8n/install cua agent.
# Port tu tinovn/n8n-manage/install-server.sh. Khac biet so voi ban goc:
#   - Khong cai Nginx/Certbot: agent chay PROXY_MODE=caddy, ghi site file vao
#     /etc/vps-ai/caddy/sites/n8n.caddy (patches/n8n-manage-caddy.patch neu
#     upstream chua ho tro)
#   - update-agent.sh rieng: ap lai patch sau git pull, KHONG chay upgrade.sh
#     cua upstream (script do clone lai repo goc va ha Node ve 20)
#   - Node.js dung chung (24) thay vi Node 20
# Bien vao: N8N_DOMAIN, MGMT_API_KEY, ACME_EMAIL, N8N_REF, N8N_IPS
# =============================================================================

readonly N8N_AGENT_DIR="/opt/n8n-agent"
readonly N8N_AGENT_REPO="https://github.com/tinovn/n8n-manage.git"
readonly N8N_INSTANCE_DIR="/opt/n8n"
readonly N8N_AGENT_ENV="${N8N_AGENT_DIR}/.env"
readonly N8N_PATCH_DIR="/opt/vps-ai/patches"
readonly N8N_DEFAULT_IPS="103.130.216.5,127.0.0.1"

install_n8n() {
  n8n_install_docker
  n8n_disable_nginx
  n8n_install_agent
  n8n_write_units
  ufw_allow "${N8N_AGENT_PORT}/tcp" n8n-agent
  systemctl enable n8n-agent >/dev/null 2>&1
  systemctl restart n8n-agent
  wait_http "http://127.0.0.1:${N8N_AGENT_PORT}/api/n8n/status" 30 2 \
    || log "WARN: n8n-agent chua phan hoi sau 60s"

  n8n_prepull_images
  n8n_install_instance
}

n8n_install_docker() {
  if ! command -v docker &>/dev/null; then
    log "Cai Docker + compose plugin"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      > /etc/apt/sources.list.d/docker.list
    apt_retry apt-get -qqy update
    apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  systemctl enable --now docker >/dev/null 2>&1
  log "Docker: $(docker --version)"
}

# VPS da cai n8n-manage ban cu (nginx + certbot) — nhuong cong 80/443 cho Caddy
n8n_disable_nginx() {
  if systemctl is-active --quiet nginx 2>/dev/null; then
    log "WARN: nginx dang chay — dung + disable de Caddy dung cong 80/443"
    systemctl disable --now nginx >/dev/null 2>&1 || true
  fi
}

# Dam bao source agent ho tro PROXY_MODE=caddy (no-op khi upstream da merge)
n8n_ensure_caddy_support() {
  local dir="$1"
  if grep -q "PROXY_MODE" "${dir}/src/n8n/n8n.service.ts"; then
    return 0
  fi
  log "Ap patch Caddy cho n8n-agent"
  git -C "$dir" apply --3way "${N8N_PATCH_DIR}/n8n-manage-caddy.patch" \
    || git -C "$dir" apply "${N8N_PATCH_DIR}/n8n-manage-caddy.patch" \
    || die "Khong ap duoc patches/n8n-manage-caddy.patch len n8n-manage@${N8N_REF}"
}

n8n_install_agent() {
  log "Cai n8n-agent (n8n-manage@${N8N_REF})"
  mkdir -p "$N8N_PATCH_DIR"
  install -m 0644 "${SELF_DIR}/patches/n8n-manage-caddy.patch" "${N8N_PATCH_DIR}/n8n-manage-caddy.patch"

  # Giu .env (API key, IP whitelist) khi clone lai
  local saved_env=""
  if [[ -f "$N8N_AGENT_ENV" ]]; then
    saved_env="$(mktemp)"
    cp "$N8N_AGENT_ENV" "$saved_env"
  fi
  systemctl stop n8n-agent 2>/dev/null || true
  rm -rf "$N8N_AGENT_DIR"
  git clone "$N8N_AGENT_REPO" "$N8N_AGENT_DIR" >>"$LOG_FILE" 2>&1 || die "git clone n8n-manage loi"
  git -C "$N8N_AGENT_DIR" checkout "$N8N_REF" >>"$LOG_FILE" 2>&1 \
    || log "WARN: khong checkout duoc '${N8N_REF}', dung nhanh mac dinh"
  # upgrade.sh cua upstream se bi update-agent.sh goc chay moi lan boot — khong dung
  rm -f "${N8N_AGENT_DIR}/upgrade.sh"
  n8n_ensure_caddy_support "$N8N_AGENT_DIR"
  if [[ -n "$saved_env" ]]; then
    cp "$saved_env" "$N8N_AGENT_ENV"
    rm -f "$saved_env"
  fi

  (cd "$N8N_AGENT_DIR" && npm install --no-audit --no-fund --loglevel=error && npm run build) >>"$LOG_FILE" 2>&1 \
    || die "Build n8n-agent loi — xem ${LOG_FILE}"

  local ips
  ips="$(read_env_value "$N8N_AGENT_ENV" ALLOWED_IP_RANGES)"
  ips="${N8N_IPS:-${ips:-$N8N_DEFAULT_IPS}}"
  upsert_env "$N8N_AGENT_ENV" PORT "$N8N_AGENT_PORT"
  upsert_env "$N8N_AGENT_ENV" AGENT_API_KEY "$MGMT_API_KEY"
  upsert_env "$N8N_AGENT_ENV" ALLOWED_IP_RANGES "$ips"
  upsert_env "$N8N_AGENT_ENV" PROXY_MODE caddy
  upsert_env "$N8N_AGENT_ENV" CADDY_SITES_DIR "$CADDY_SITES_DIR"
}

n8n_write_units() {
  cat > /etc/systemd/system/n8n-agent.service <<EOF
[Unit]
Description=N8N Agent Service
After=network-online.target docker.service caddy.service
Wants=network-online.target

[Service]
ExecStart=$(command -v node) ${N8N_AGENT_DIR}/dist/main.js
Restart=always
User=root
Environment=NODE_ENV=production
WorkingDirectory=${N8N_AGENT_DIR}

[Install]
WantedBy=multi-user.target
EOF

  # Tu cap nhat agent khi boot (giong ban goc) nhung giu patch Caddy + .env,
  # va neu build loi thi quay lai ban dang chay thay vi de agent chet.
  cat > "${N8N_AGENT_DIR}/update-agent.sh" <<EOF
#!/bin/bash
# Managed by vps-ai-management
set -uo pipefail
APP_DIR="${N8N_AGENT_DIR}"
REF="${N8N_REF}"
PATCH="${N8N_PATCH_DIR}/n8n-manage-caddy.patch"
cd "\$APP_DIR" || exit 1
prev="\$(git rev-parse HEAD)"
git fetch --quiet origin || { echo "fetch loi, giu ban hien tai"; exit 0; }
target="\$(git rev-parse "origin/\${REF}" 2>/dev/null || git rev-parse "\${REF}")"
if [[ "\$target" == "\$prev" ]]; then echo "n8n-agent da moi nhat (\${prev:0:8})"; exit 0; fi
git reset --hard --quiet "\$target"
rm -f upgrade.sh
grep -q PROXY_MODE src/n8n/n8n.service.ts || git apply --3way "\$PATCH" || git apply "\$PATCH" || {
  echo "Patch Caddy khong ap duoc len \${target:0:8} — quay lai \${prev:0:8}"
  git reset --hard --quiet "\$prev"; git apply "\$PATCH" 2>/dev/null; exit 1; }
if npm install --no-audit --no-fund --loglevel=error && npm run build; then
  systemctl restart n8n-agent
  echo "Da cap nhat n8n-agent \${prev:0:8} -> \${target:0:8}"
else
  echo "Build loi — quay lai \${prev:0:8}"
  git reset --hard --quiet "\$prev"
  grep -q PROXY_MODE src/n8n/n8n.service.ts || git apply "\$PATCH"
  npm install --no-audit --no-fund --loglevel=error && npm run build
  systemctl restart n8n-agent
  exit 1
fi
EOF
  chmod +x "${N8N_AGENT_DIR}/update-agent.sh"

  cat > /etc/systemd/system/n8n-agent-update.service <<EOF
[Unit]
Description=Auto update n8n-agent on boot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${N8N_AGENT_DIR}/update-agent.sh
EOF

  cat > /etc/systemd/system/n8n-agent-update.timer <<'EOF'
[Unit]
Description=Run n8n-agent update on boot

[Timer]
OnBootSec=60s
Unit=n8n-agent-update.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable n8n-agent-update.timer >/dev/null 2>&1
}

# Keo san base image de buoc `docker compose up --build` trong agent nhanh + it OOM
n8n_prepull_images() {
  local img
  for img in alpine:3.22 \
             dockerhub.tino.org/library/n8nio/n8n:latest \
             dockerhub.tino.org/library/postgres:16 \
             dockerhub.tino.org/library/redis:7-alpine \
             dockerhub.tino.org/library/nocodb/nocodb:latest; do
    log "docker pull ${img}"
    docker pull "$img" >>"$LOG_FILE" 2>&1 || log "WARN: khong pull duoc ${img} (build se tu keo)"
  done
}

# Ghi site Caddy truc tiep — dung khi n8n da duoc cai tu truoc (ban nginx cu)
n8n_write_site() {
  local domain="$1"
  cat > "${CADDY_SITES_DIR}/n8n.caddy" <<EOF
# Managed by n8n-agent (PROXY_MODE=caddy) — do not edit, rewritten on install/change-domain
${domain} {
    tls ${ACME_EMAIL}

    request_body {
        max_size 100MB
    }

    handle_path /nocodb/* {
        reverse_proxy 127.0.0.1:8080
    }

    handle /mcp/* {
        reverse_proxy 127.0.0.1:5678 {
            flush_interval -1
            transport http {
                read_timeout 1h
                write_timeout 1h
            }
        }
    }

    handle {
        reverse_proxy 127.0.0.1:5678 {
            flush_interval -1
        }
    }
}
EOF
}

n8n_install_instance() {
  if [[ -f "${N8N_INSTANCE_DIR}/docker-compose.yml" ]]; then
    local current
    current="$(read_env_value "${N8N_INSTANCE_DIR}/.env" N8N_HOST)"
    log "n8n instance da ton tai (${current:-?}) — chi chuyen reverse proxy sang Caddy"
    [[ -f "${CADDY_SITES_DIR}/n8n.caddy" ]] || n8n_write_site "${current:-$N8N_DOMAIN}"
    return 0
  fi

  dns_points_here "$N8N_DOMAIN" 3 \
    || log "LUU Y: DNS ${N8N_DOMAIN} chua tro ve ${SERVER_IP} — van cai; Caddy tu cap SSL khi DNS dung"

  log "Goi n8n-agent: POST /api/n8n/install (domain=${N8N_DOMAIN})"
  local resp task_id status="" i
  resp="$(curl -s -X POST "http://127.0.0.1:${N8N_AGENT_PORT}/api/n8n/install" \
    -H "Content-Type: application/json" \
    -H "tng-api-key: ${MGMT_API_KEY}" \
    -d "$(jq -nc --arg d "$N8N_DOMAIN" --arg e "$ACME_EMAIL" '{domain: $d, email: $e}')")" || true
  task_id="$(echo "$resp" | jq -r '.taskId // empty' 2>/dev/null || true)"
  [[ -n "$task_id" ]] || die "n8n-agent tu choi install: ${resp:-khong phan hoi}"

  # docker compose build + migration DB co the mat 5-15 phut tren VPS yeu
  log "Cho task ${task_id} (toi da 25 phut)..."
  for ((i = 1; i <= 150; i++)); do
    status="$(curl -s "http://127.0.0.1:${N8N_AGENT_PORT}/api/tasks/${task_id}" | jq -r '.status // empty' 2>/dev/null || true)"
    [[ "$status" == "completed" || "$status" == "failed" ]] && break
    (( i % 6 == 0 )) && log "  n8n install: ${status:-?} ($((i * 10))s)"
    sleep 10
  done
  if [[ "$status" == "completed" ]]; then
    log "n8n cai xong: https://${N8N_DOMAIN}"
  elif [[ "$status" == "failed" ]]; then
    die "n8n install that bai: $(curl -s "http://127.0.0.1:${N8N_AGENT_PORT}/api/tasks/${task_id}" | jq -r '.error')"
  else
    log "WARN: n8n install van dang chay (${status:-?}) — theo doi: curl -s localhost:${N8N_AGENT_PORT}/api/tasks/${task_id}"
  fi
}
