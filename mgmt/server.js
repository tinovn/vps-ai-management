#!/usr/bin/env node
// =============================================================================
// vps-ai-mgmt — management API chung cua vps-ai-management (:9990)
// Auth: Authorization: Bearer <MGMT_API_KEY trong /opt/vps-ai/.env>
//
//   GET  /health                      khong can auth
//   GET  /api/apps                    danh sach app: enabled/disabled, trang thai, RAM
//   GET  /api/apps/:app               chi tiet 1 app
//   POST /api/apps/:app/disable       tat app (stop + disable systemd, go site Caddy)
//   POST /api/apps/:app/enable        bat lai app
//   GET  /api/system                  RAM / swap / disk / load cua VPS
//
// Bat/tat thuc hien qua CLI `vps-ai disable|enable <app>` (1 nguon logic cho
// ca panel lan quan tri vien SSH).
// =============================================================================
'use strict';

const http = require('http');
const fs = require('fs');
const crypto = require('crypto');
const { execFile } = require('child_process');

const PORT = Number(process.env.VPS_AI_MGMT_PORT || 9990);
const ENV_FILE = '/opt/vps-ai/.env';
const CLI = '/usr/local/bin/vps-ai';
const APPS = ['hermes', 'n8n', 'openclaw'];

// Unit cua tung app (de bao trang thai + RAM). hermes.target la target, khong co RAM.
const APP_UNITS = {
  hermes: ['hermes-gateway.service', 'hermes-dashboard.service', 'hermes-mgmt.service',
           'hermes-rag.service', 'hermes-openviking.service'],
  openclaw: ['openclaw.service', 'openclaw-mgmt.service'],
  n8n: ['n8n-agent.service'],
};

function readEnv(file) {
  const out = {};
  try {
    for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (m) out[m[1]] = m[2];
    }
  } catch { /* file chua co */ }
  return out;
}

function listOf(v) {
  return (v || '').split(',').map((s) => s.trim()).filter(Boolean);
}

function run(cmd, args, timeoutMs = 15000) {
  return new Promise((resolve) => {
    execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 4 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ code: err ? (typeof err.code === 'number' ? err.code : 1) : 0, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

function authorized(req) {
  const key = readEnv(ENV_FILE).MGMT_API_KEY || '';
  const m = (req.headers.authorization || '').match(/^Bearer\s+(.+)$/i);
  if (!key || !m) return false;
  const a = Buffer.from(m[1].trim());
  const b = Buffer.from(key);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function send(res, status, body) {
  const data = JSON.stringify(body);
  res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Content-Length': Buffer.byteLength(data) });
  res.end(data);
}

// systemctl show cho nhieu unit -> { unit: { active, enabled, memoryMb } }
async function unitStates(units) {
  const r = await run('systemctl', ['show', '-p', 'Id,LoadState,ActiveState,UnitFileState,MemoryCurrent', '--', ...units]);
  const states = {};
  for (const block of r.stdout.split('\n\n')) {
    const p = {};
    for (const line of block.split('\n')) {
      const i = line.indexOf('=');
      if (i > 0) p[line.slice(0, i)] = line.slice(i + 1);
    }
    if (!p.Id || p.LoadState === 'not-found') continue;
    const mem = Number(p.MemoryCurrent);
    states[p.Id] = {
      active: p.ActiveState,
      enabled: p.UnitFileState,
      memoryMb: Number.isFinite(mem) && mem < 2 ** 60 ? Math.round(mem / 1048576) : null,
    };
  }
  return states;
}

function parseDockerMem(s) {
  const m = (s || '').match(/([\d.]+)\s*([KMG]i?B)/i);
  if (!m) return 0;
  const n = parseFloat(m[1]);
  const unit = m[2].toUpperCase();
  if (unit.startsWith('G')) return n * 1024;
  if (unit.startsWith('K')) return n / 1024;
  return n;
}

async function n8nContainers() {
  if (!fs.existsSync('/opt/n8n/docker-compose.yml')) return [];
  const ps = await run('docker', ['compose', '-f', '/opt/n8n/docker-compose.yml', 'ps', '--format', '{{.ID}} {{.Service}} {{.State}}']);
  const rows = ps.stdout.trim().split('\n').filter(Boolean).map((l) => {
    const [id, service, state] = l.split(' ');
    return { id, service, state, memoryMb: null };
  });
  if (rows.length) {
    const st = await run('docker', ['stats', '--no-stream', '--format', '{{.ID}} {{.MemUsage}}', ...rows.map((r) => r.id)]);
    for (const line of st.stdout.trim().split('\n')) {
      const [id, ...rest] = line.split(' ');
      const row = rows.find((r) => id && r.id.startsWith(id.slice(0, 12)));
      if (row) row.memoryMb = Math.round(parseDockerMem(rest.join(' ')));
    }
  }
  return rows.map(({ id, ...r }) => r);
}

function appDomain(app) {
  if (app === 'hermes') return readEnv('/opt/hermes/.env').DOMAIN || null;
  if (app === 'openclaw') return (readEnv('/opt/openclaw/.env').DOMAIN || '').replace(/^https?:\/\//, '') || null;
  if (app === 'n8n') return readEnv('/opt/n8n/.env').N8N_HOST || null;
  return null;
}

async function appInfo(app) {
  const env = readEnv(ENV_FILE);
  const installed = listOf(env.INSTALLED_APPS).includes(app);
  const disabled = listOf(env.DISABLED_APPS).includes(app);
  const info = { app, installed, enabled: installed && !disabled, domain: installed ? appDomain(app) : null };
  if (!installed) return info;

  const states = await unitStates(APP_UNITS[app]);
  info.services = Object.entries(states).map(([unit, s]) => ({ unit, ...s }));
  let mem = info.services.reduce((sum, s) => sum + (s.memoryMb || 0), 0);
  if (app === 'n8n') {
    info.containers = await n8nContainers();
    mem += info.containers.reduce((sum, c) => sum + (c.memoryMb || 0), 0);
  }
  const running = info.services.filter((s) => s.active === 'active').length;
  info.status = running === 0 ? 'stopped' : running === info.services.length ? 'running' : 'partial';
  info.memoryMb = mem;
  return info;
}

async function systemInfo() {
  const mem = {};
  for (const line of fs.readFileSync('/proc/meminfo', 'utf8').split('\n')) {
    const m = line.match(/^(\w+):\s+(\d+)/);
    if (m) mem[m[1]] = Math.round(Number(m[2]) / 1024);
  }
  const df = await run('df', ['-BM', '--output=size,used,avail', '/']);
  const [size, used, avail] = (df.stdout.trim().split('\n')[1] || '').trim().split(/\s+/).map((v) => parseInt(v, 10));
  const load = fs.readFileSync('/proc/loadavg', 'utf8').split(' ').slice(0, 3).map(Number);
  return {
    memory: { totalMb: mem.MemTotal, availableMb: mem.MemAvailable, usedMb: mem.MemTotal - mem.MemAvailable },
    swap: { totalMb: mem.SwapTotal, usedMb: mem.SwapTotal - mem.SwapFree },
    disk: { totalMb: size, usedMb: used, availableMb: avail },
    load,
  };
}

// Chi 1 thao tac bat/tat tai 1 thoi diem (cung dung chung Caddy reload)
let busy = null;

async function toggle(app, action, res) {
  if (busy) return send(res, 409, { ok: false, error: `Dang xu ly: ${busy}` });
  busy = `${action} ${app}`;
  try {
    const r = await run(CLI, [action, app], 300000);
    const output = (r.stdout + r.stderr).trim();
    if (r.code === 2 || r.code === 3) return send(res, r.code === 2 ? 400 : 404, { ok: false, error: output });
    if (r.code !== 0) return send(res, 500, { ok: false, error: output });
    return send(res, 200, { ok: true, output, data: await appInfo(app) });
  } finally {
    busy = null;
  }
}

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, 'http://localhost');
    const path = url.pathname.replace(/\/+$/, '') || '/';

    if (req.method === 'GET' && path === '/health') return send(res, 200, { ok: true });
    if (!authorized(req)) return send(res, 401, { ok: false, error: 'Unauthorized' });

    if (req.method === 'GET' && path === '/api/apps') {
      const data = await Promise.all(APPS.map(appInfo));
      return send(res, 200, { ok: true, data });
    }
    if (req.method === 'GET' && path === '/api/system') {
      return send(res, 200, { ok: true, data: await systemInfo() });
    }

    const m = path.match(/^\/api\/apps\/([a-z0-9]+)(?:\/(enable|disable))?$/);
    if (m) {
      const [, app, action] = m;
      if (!APPS.includes(app)) return send(res, 400, { ok: false, error: `App khong hop le: ${app} (hermes | n8n | openclaw)` });
      if (!action && req.method === 'GET') return send(res, 200, { ok: true, data: await appInfo(app) });
      if (action && req.method === 'POST') return toggle(app, action, res);
      return send(res, 405, { ok: false, error: 'Method not allowed' });
    }
    return send(res, 404, { ok: false, error: 'Not found' });
  } catch (e) {
    return send(res, 500, { ok: false, error: e.message });
  }
});

server.listen(PORT, '0.0.0.0', () => console.log(`[vps-ai-mgmt] listening on :${PORT}`));
