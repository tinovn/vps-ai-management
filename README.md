# vps-ai-management

Bộ cài gộp **Hermes Agent**, **n8n** và **OpenClaw** lên cùng 1 VPS Ubuntu 24.04 bằng 1 lệnh — chọn app nào cài app đó.

Gộp từ:
- [tinovn/vps-hermes-management](https://github.com/tinovn/vps-hermes-management)
- [tinovn/vps-openclaw-management](https://github.com/tinovn/vps-openclaw-management)
- [tinovn/n8n-manage](https://github.com/tinovn/n8n-manage)

## Cài đặt

```bash
curl -fsSL https://raw.githubusercontent.com/tinovn/vps-ai-management/main/install.sh | \
  bash -s -- --domain <TEN_MIEN> [--mgmt-key <KEY>] --hermes --n8n --openclaw
```

Chỉ cần 1 trong các flag `--hermes`, `--n8n`, `--openclaw` (hoặc `--all`). Chạy lại với flag khác để **cài thêm app** vào VPS đã có — token và domain cũ được giữ nguyên.

Cho HostBill / SSH timeout ngắn: dùng `bootstrap.sh` với cùng các flag (tự detach, chờ cloud-init, reboot rồi cài):

```bash
ssh root@vps "curl -fsSL https://raw.githubusercontent.com/tinovn/vps-ai-management/main/bootstrap.sh | \
  bash -s -- --domain <TEN_MIEN> --mgmt-key <KEY> --all"
# theo dõi: tail -f /var/log/vps-ai-install.log
```

### Flags

| Flag | Ý nghĩa |
|---|---|
| `--hermes` / `--n8n` / `--openclaw` / `--all` | App cần cài |
| `--domain <FQDN>` | Tên miền gốc (bỏ trống: `hostname -f`, rồi `<ip>.sslip.io`) |
| `--mgmt-key <KEY>` | API key **dùng chung** cho cả 3 management API (bỏ trống: tự sinh) |
| `--email <EMAIL>` | Email Let's Encrypt (mặc định `admin@<domain>`) |
| `--hermes-domain` / `--n8n-domain` / `--openclaw-domain` | Ghi đè tên miền riêng từng app |
| `--ref <REF>` | Ref của repo này (mặc định `main`) |
| `--hermes-ref <REF>` | Ref upstream `NousResearch/hermes-agent` |
| `--skip-zalo`, `--no-rag` | Hermes: bỏ plugin Zalo cá nhân / RAG MCP |
| `--n8n-ref <REF>` | Ref `tinovn/n8n-manage` |
| `--ips <CIDR,...>` | n8n-agent: IP/CIDR được phép gọi API |

### Tên miền & DNS

| Số app trên VPS | Tên miền |
|---|---|
| 1 app | chính `<TEN_MIEN>` |
| nhiều app | `hermes.<TEN_MIEN>`, `n8n.<TEN_MIEN>`, `openclaw.<TEN_MIEN>` |

Trỏ A record của từng tên miền (hoặc wildcard `*.<TEN_MIEN>`) về IP VPS **trước khi cài** để có Let's Encrypt ngay. Khi cài thêm app sau này, app cũ giữ nguyên tên miền đang dùng.

Nếu DNS chưa trỏ lúc cài, cả 3 app dùng **chứng chỉ tự ký** (`tls internal`) để HTTPS vẫn vào được (trình duyệt cảnh báo), Caddy không xin Let's Encrypt/ZeroSSL liên tục nên không lo dính rate limit khi cài lại nhiều lần. Trỏ DNS xong thì đổi domain qua management API để lên Let's Encrypt:

| App | Endpoint |
|---|---|
| Hermes | `PUT :9997/api/domain` |
| OpenClaw | `PUT :9998/api/domain` |
| n8n | `PATCH :7071/api/n8n/change-domain` (gọi lại với chính domain đó cũng được) |

## Sau khi cài

```bash
vps-ai info              # URL, token, API key từng app
vps-ai status            # trạng thái service / container
vps-ai restart <app|all>
vps-ai logs <app>
vps-ai add n8n           # cài thêm app
vps-ai disable n8n       # tắt hẳn app không dùng (tiết kiệm RAM), dữ liệu giữ nguyên
vps-ai enable n8n        # bật lại
vps-ai apps              # app nào đang enabled / disabled
vps-ai reload-caddy
```

### API bật/tắt app cho panel (`:9990`)

Tài liệu đầy đủ cho panel: [docs/vps-ai-mgmt-api.md](docs/vps-ai-mgmt-api.md).

Header: `Authorization: Bearer <MGMT_API_KEY>` (key dùng chung, `--mgmt-key` lúc cài).

| Method | Path | Mô tả |
|---|---|---|
| GET | `/health` | Không cần auth |
| GET | `/api/apps` | Danh sách app: `enabled`, `status` (`running` / `partial` / `stopped`), `memoryMb`, `domain`, từng service / container |
| GET | `/api/apps/{app}` | Chi tiết 1 app (`hermes` / `n8n` / `openclaw`) |
| POST | `/api/apps/{app}/disable` | Tắt app |
| POST | `/api/apps/{app}/enable` | Bật lại app |
| GET | `/api/system` | RAM / swap / disk / load của VPS |

Disable một app:
- `systemctl disable --now` toàn bộ unit của app, kể cả management API riêng của nó → **không tự chạy lại sau reboot**
- n8n: `docker compose down` (xoá container, **giữ volume** — workflow, database, NocoDB còn nguyên)
- Gỡ site của app khỏi Caddy (`sites-disabled/`), các app khác không bị ảnh hưởng

Enable thì làm ngược lại (n8n mất ~15 giây để dựng lại container). Mã lỗi: `400` app không hợp lệ, `404` app chưa cài, `409` đang có thao tác bật/tắt khác, `500` lỗi khi chạy (chi tiết trong `error`).

```bash
curl -X POST -H "Authorization: Bearer $KEY" http://<IP>:9990/api/apps/n8n/disable
# {"ok":true,"output":"...","data":{"app":"n8n","enabled":false,"status":"stopped","memoryMb":0,...}}
```

Đo thực tế (VPS 6GB, cài cả 3 app): Hermes ~1.2GB, n8n ~1.2–2GB, OpenClaw ~0.8–1.3GB; tắt cả 3 còn ~450MB dùng.

### Cổng

| Cổng | Dịch vụ | Public |
|---|---|---|
| 80, 443 | Caddy (dùng chung) | ✔ |
| 9990 | vps-ai management API — bật/tắt app (`Authorization: Bearer <key>`) | ✔ |
| 9997 | Hermes management API (`Authorization: Bearer <key>`) | ✔ |
| 9998 | OpenClaw management API (`Authorization: Bearer <key>`) | ✔ |
| 7071 | n8n-agent (`tng-api-key: <key>`, IP whitelist) | ✔ |
| 9119 / 9996 / 3838 | Hermes dashboard / RAG MCP / Zalo sidecar | localhost |
| 18789 | OpenClaw gateway | localhost (UFW chặn) |
| 5678 / 8080 | n8n / NocoDB | localhost |

API của từng app giữ nguyên như repo gốc — HostBill gọi các cổng trên như trước, chỉ khác là cả 3 dùng chung 1 key.

## Kiến trúc

```
                   ┌───────────────── Caddy :80/:443 ─────────────────┐
                   │ /etc/caddy/Caddyfile → import sites/*.caddy     │
                   └──────┬───────────────────┬───────────────────┬───┘
         hermes.<domain>  │   openclaw.<domain>│        n8n.<domain>│
             :9119 (cookie gate)   :18789 (+ /login → :9998)   :5678, /nocodb → :8080
```

Ba repo gốc xung đột nhau ở mấy chỗ, bộ này xử lý như sau:

| Xung đột | Cách xử lý |
|---|---|
| Hermes & OpenClaw cùng ghi đè `caddy.service.d/override.conf` trỏ tới Caddyfile riêng | 1 Caddyfile chung `import /etc/vps-ai/caddy/sites/*.caddy`, mỗi app 1 site file |
| Cả hai dùng biến `DOMAIN`/`CADDY_TLS` trong `.env` riêng (mgmt API sửa trực tiếp) | `vps-ai-caddy-env` đọc từng `.env`, thêm prefix (`HERMES_DOMAIN`, `OPENCLAW_DOMAIN`…) trước mỗi lần Caddy start/reload — mgmt API đổi domain + `systemctl restart caddy` vẫn hoạt động như cũ |
| n8n dùng Nginx + Certbot trên 80/443 | n8n-agent chạy `PROXY_MODE=caddy`: ghi `sites/n8n.caddy` (DNS chưa trỏ → `tls internal`) và reload Caddy ([patches/n8n-manage-caddy.patch](patches/n8n-manage-caddy.patch)) |
| Caddy gọi `sudo` để cài CA nội bộ vào trust store khi dùng cert tự ký (user `caddy` không có sudo → journal đầy lỗi) | `skip_install_trust` trong global options |
| Hermes RAG và OpenClaw mgmt cùng cổng 9998 | RAG chuyển sang 9996 (`RAG_PORT` trong `/opt/hermes/.env`) |
| Node 22 (Hermes) / 24 (OpenClaw) / 20 (n8n) | Cài Node 24 một lần, không hạ cấp |
| `update-agent.sh` của n8n chạy `upgrade.sh` upstream mỗi lần boot (clone lại repo gốc, hạ Node về 20) | `update-agent.sh` riêng: pull, áp lại patch, build lỗi thì quay về bản cũ, không chạy `upgrade.sh` |
| NocoDB bind `0.0.0.0:8080` (Docker vượt qua UFW) | Bind `127.0.0.1:8080`, truy cập qua `https://<n8n-domain>/nocodb/` |

### Cấu trúc repo

```
install.sh              entry point (tự tải repo khi chạy qua curl | bash)
bootstrap.sh            bản cho HostBill: detach → cloud-init → reboot → install.sh
lib/common.sh           apt-lock, domain/DNS, .env, Node, swap, UFW
lib/caddy.sh            Caddy dùng chung + override systemd
lib/run-module.sh       chạy từng module trong tiến trình riêng
modules/{hermes,n8n,openclaw}.sh
caddy/Caddyfile, caddy/sites/{hermes,openclaw}.caddy
bin/vps-ai              CLI quản trị (info, status, enable/disable app...)
mgmt/server.js          vps-ai management API :9990 (Node, không dependency)
bin/vps-ai-caddy-env    sinh /run/vps-ai/caddy.env cho Caddy
patches/n8n-manage-caddy.patch
```

### Vị trí trên VPS

| Đường dẫn | Nội dung |
|---|---|
| `/opt/vps-ai/.env` | domain gốc, MGMT key dùng chung, danh sách app đã cài |
| `/opt/vps-ai/src` | bản source dùng cho `vps-ai add` |
| `/opt/hermes`, `/opt/hermes-mgmt`, `/opt/hermes-rag`, `/root/.hermes` | Hermes (như repo gốc) |
| `/opt/openclaw`, `/opt/openclaw-mgmt` | OpenClaw (như repo gốc) |
| `/opt/n8n-agent`, `/opt/n8n` | n8n-agent + docker compose của n8n |
| `/etc/vps-ai/caddy/sites/` | site file Caddy của từng app |

## Yêu cầu

- Ubuntu 24.04 (Hermes bắt buộc 24.04; n8n/OpenClaw chạy được trên 22.04)
- Chạy bằng root
- RAM khuyến nghị (đo thực tế, đã tính phần dùng sau khi cài):

  | Số app | RAM khuyến nghị | Disk trống |
  |---|---|---|
  | 1 app | **tối thiểu 4GB** | 8GB (OpenClaw 6GB) |
  | 2 app | 6GB | ~14GB |
  | 3 app | 8GB | ~18GB |

  VPS 2GB vẫn cài được (installer cảnh báo và tự tạo swap 4GB) nhưng sau cài chỉ còn ~300–400MB trống, app chạy chậm — không khuyến nghị dùng thật.
- Google Chrome cho OpenClaw chỉ có bản amd64; trên arm64 browser tool của OpenClaw sẽ không dùng được.

## Ghi chú

- Management API của từng app vẫn tự cập nhật từ repo gốc (`/api/self-update`, `/api/upgrade-mgmt`…); các endpoint đó không đụng tới cấu hình Caddy dùng chung.
- Nên đưa [patches/n8n-manage-caddy.patch](patches/n8n-manage-caddy.patch) vào upstream `tinovn/n8n-manage` (mặc định vẫn là `nginx`, tương thích ngược). Khi upstream đã có `PROXY_MODE`, installer tự bỏ qua bước áp patch.
