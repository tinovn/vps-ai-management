# vps-ai-mgmt API — bật/tắt app trên VPS

API chung của bộ `vps-ai-management`, dùng để panel bật/tắt Hermes, n8n, OpenClaw trên VPS của khách. App bị tắt sẽ không chạy, không tự khởi động lại sau reboot, nên không tốn RAM/CPU. Dữ liệu được giữ nguyên.

## Thông tin chung

| | |
|---|---|
| Base URL | `http://<IP_VPS>:9990` |
| Auth | Header `Authorization: Bearer <MGMT_API_KEY>`. Đây là key truyền vào `--mgmt-key` lúc cài, dùng chung với API của Hermes (:9997) và OpenClaw (:9998). |
| Content-Type | Response luôn là `application/json`. Request không cần body. |
| Định dạng response | `{"ok": true, "data": ...}` hoặc `{"ok": false, "error": "<thông báo>"}` |
| Tên app hợp lệ | `hermes`, `n8n`, `openclaw` |

Chỉ VPS cài từ commit `8538874` (15/10/2026) trở đi mới có API này. Với VPS cài trước đó, `GET /health` không kết nối được; panel nên ẩn nút bật/tắt cho các VPS này.

## Endpoints

| Method | Path | Auth | Mô tả |
|---|---|---|---|
| GET | `/health` | không | Kiểm tra API còn sống |
| GET | `/api/apps` | có | Trạng thái cả 3 app |
| GET | `/api/apps/{app}` | có | Trạng thái 1 app |
| POST | `/api/apps/{app}/disable` | có | Tắt app |
| POST | `/api/apps/{app}/enable` | có | Bật lại app |
| GET | `/api/system` | có | RAM / swap / disk / load của VPS |

### GET /health

```json
{ "ok": true }
```

### GET /api/apps

Luôn trả đủ 3 phần tử, theo thứ tự `hermes`, `n8n`, `openclaw`, kể cả app chưa cài.

```bash
curl -H "Authorization: Bearer $KEY" http://<IP>:9990/api/apps
```

```json
{
  "ok": true,
  "data": [
    {
      "app": "hermes",
      "installed": true,
      "enabled": true,
      "domain": "hermes.mg8a7liv7.tino.page",
      "services": [
        { "unit": "hermes-gateway.service",   "active": "active", "enabled": "enabled", "memoryMb": 232 },
        { "unit": "hermes-dashboard.service", "active": "active", "enabled": "enabled", "memoryMb": 213 },
        { "unit": "hermes-mgmt.service",      "active": "active", "enabled": "enabled", "memoryMb": 50 },
        { "unit": "hermes-rag.service",       "active": "active", "enabled": "enabled", "memoryMb": 865 }
      ],
      "status": "running",
      "memoryMb": 1360
    },
    {
      "app": "n8n",
      "installed": true,
      "enabled": true,
      "domain": "n8n.mg8a7liv7.tino.page",
      "services": [
        { "unit": "n8n-agent.service", "active": "active", "enabled": "enabled", "memoryMb": 60 }
      ],
      "containers": [
        { "service": "n8n",        "state": "running", "memoryMb": 374 },
        { "service": "n8n-worker", "state": "running", "memoryMb": 298 },
        { "service": "nocodb",     "state": "running", "memoryMb": 814 },
        { "service": "postgres",   "state": "running", "memoryMb": 39 },
        { "service": "redis",      "state": "running", "memoryMb": 7 }
      ],
      "status": "running",
      "memoryMb": 1592
    },
    {
      "app": "openclaw",
      "installed": true,
      "enabled": true,
      "domain": "openclaw.mg8a7liv7.tino.page",
      "services": [
        { "unit": "openclaw.service",      "active": "active", "enabled": "enabled", "memoryMb": 934 },
        { "unit": "openclaw-mgmt.service", "active": "active", "enabled": "enabled", "memoryMb": 21 }
      ],
      "status": "running",
      "memoryMb": 955
    }
  ]
}
```

App chưa cài chỉ có 4 trường:

```json
{ "app": "openclaw", "installed": false, "enabled": false, "domain": null }
```

#### Các trường

| Trường | Kiểu | Ý nghĩa |
|---|---|---|
| `app` | string | `hermes` / `n8n` / `openclaw` |
| `installed` | bool | App đã được cài trên VPS chưa. `false` thì panel không hiện nút bật/tắt. |
| `enabled` | bool | **Trạng thái nên hiển thị trên công tắc của panel.** `false` nghĩa là đã bị tắt qua API/CLI. |
| `status` | string | Trạng thái chạy thực tế: `running` (mọi service đang chạy), `partial` (một phần đang chạy), `stopped` (không service nào chạy). Không có trường này khi `installed=false`. |
| `memoryMb` | number | Tổng RAM app đang dùng (MB), gồm các service và container. Khi app đang tắt thì bằng 0. |
| `domain` | string \| null | Tên miền của app |
| `services[]` | array | Các systemd service: `unit`, `active` (`active` / `inactive` / `failed` / `activating`...), `enabled` (`enabled` / `disabled`), `memoryMb` (có thể là `null`) |
| `containers[]` | array | Chỉ có với n8n: `service`, `state` (`running` / `exited`...), `memoryMb`. Mảng rỗng khi n8n đang tắt. |

Một số lưu ý khi xử lý dữ liệu:
- `enabled=true` nhưng `status` khác `running` nghĩa là app đang khởi động hoặc bị lỗi. Panel nên hiện cảnh báo.
- Danh sách `services` có thể khác nhau giữa các VPS. Ví dụ Hermes cài với `--no-rag` thì không có `hermes-rag.service`. Panel không nên hardcode danh sách này.

### GET /api/apps/{app}

Trả về 1 phần tử với cấu trúc giống như trên.

```bash
curl -H "Authorization: Bearer $KEY" http://<IP>:9990/api/apps/n8n
```

### POST /api/apps/{app}/disable

```bash
curl -X POST -H "Authorization: Bearer $KEY" http://<IP>:9990/api/apps/n8n/disable
```

```json
{
  "ok": true,
  "output": "Disable n8n: n8n-agent.service n8n-agent-update.timer\nDa disable n8n (du lieu giu nguyen; bat lai: vps-ai enable n8n)",
  "data": {
    "app": "n8n", "installed": true, "enabled": false, "domain": "n8n.mg8a7liv7.tino.page",
    "services": [{ "unit": "n8n-agent.service", "active": "inactive", "enabled": "disabled", "memoryMb": null }],
    "containers": [],
    "status": "stopped",
    "memoryMb": 0
  }
}
```

`data` là trạng thái của app ngay sau khi tắt, panel cập nhật giao diện trực tiếp từ đây, không cần gọi lại `GET`.

Khi tắt, API sẽ:
1. Tắt và gỡ khởi động cùng hệ thống mọi service của app, **kể cả API riêng của app** (Hermes :9997, OpenClaw :9998, n8n-agent :7071).
2. Với n8n: chạy `docker compose down`. Lệnh này xóa container nhưng giữ volume, nên workflow, credential, database và dữ liệu NocoDB còn nguyên.
3. Gỡ tên miền của app khỏi Caddy. Truy cập `https://<domain-app>` sẽ không kết nối được. Các app khác không bị ảnh hưởng.

Gọi disable với app đang tắt vẫn trả `ok: true`.

Thời gian xử lý: khoảng 1–4 giây.

### POST /api/apps/{app}/enable

```bash
curl -X POST -H "Authorization: Bearer $KEY" http://<IP>:9990/api/apps/n8n/enable
```

```json
{
  "ok": true,
  "output": "Enable n8n: n8n-agent.service n8n-agent-update.timer\nDa enable n8n",
  "data": {
    "app": "n8n", "installed": true, "enabled": true, "domain": "n8n.mg8a7liv7.tino.page",
    "services": [{ "unit": "n8n-agent.service", "active": "active", "enabled": "enabled", "memoryMb": 29 }],
    "containers": [
      { "service": "n8n", "state": "running", "memoryMb": 160 },
      { "service": "n8n-worker", "state": "running", "memoryMb": 590 },
      { "service": "nocodb", "state": "running", "memoryMb": 352 },
      { "service": "postgres", "state": "running", "memoryMb": 61 },
      { "service": "redis", "state": "running", "memoryMb": 14 }
    ],
    "status": "running",
    "memoryMb": 1206
  }
}
```

Thời gian xử lý đo thực tế: OpenClaw khoảng 1 giây, Hermes khoảng 1 giây, **n8n khoảng 15 giây** (phải dựng lại container). Request chạy đồng bộ, nên panel cần đặt **timeout tối thiểu 120 giây**.

Sau khi enable:
- `status` có thể là `running` ngay, nhưng web UI của app cần thêm vài giây mới vào được. n8n cần khoảng 10–30 giây để chạy migration database.
- API riêng của app (:9997 / :9998 / :7071) hoạt động lại.

### GET /api/system

```json
{
  "ok": true,
  "data": {
    "memory": { "totalMb": 5924, "availableMb": 1890, "usedMb": 4034 },
    "swap":   { "totalMb": 4096, "usedMb": 8 },
    "disk":   { "totalMb": 58447, "usedMb": 18474, "availableMb": 39957 },
    "load":   [1.22, 0.84, 0.34]
  }
}
```

`load` là load average 1, 5 và 15 phút.

## Mã lỗi

| HTTP | Khi nào | Ví dụ `error` |
|---|---|---|
| 400 | Tên app không hợp lệ | `App khong hop le: abc (hermes \| n8n \| openclaw)` |
| 401 | Thiếu key hoặc sai key | `Unauthorized` |
| 404 | App chưa được cài trên VPS (enable/disable), hoặc sai đường dẫn | `App 'openclaw' chua duoc cai tren VPS nay` / `Not found` |
| 405 | Sai method, ví dụ `GET .../disable` | `Method not allowed` |
| 409 | Đang có thao tác bật/tắt khác chạy trên VPS (mỗi lúc chỉ được 1 thao tác) | `Dang xu ly: enable n8n` |
| 500 | Lỗi khi bật/tắt (ví dụ docker lỗi) | Vài dòng log cuối của lệnh bị lỗi |

Khi gặp 409, panel chờ vài giây rồi thử lại, hoặc khóa nút trong lúc đang chờ response.

## Gợi ý tích hợp panel

1. **Hiển thị:** gọi `GET /api/apps`, mỗi app có `installed=true` thì hiện 1 công tắc theo `enabled`, kèm `memoryMb` và `domain`. Có thể dùng `GET /api/system` để hiện RAM còn trống, giúp khách thấy được phần RAM tiết kiệm.
2. **Bật/tắt:** gọi `POST .../enable` hoặc `.../disable`, khóa công tắc và hiện trạng thái "đang xử lý" cho tới khi có response (timeout ≥ 120 giây), rồi cập nhật giao diện từ `data` trong response.
3. **Ẩn chức năng phụ thuộc:** khi app đang `enabled=false`, ẩn hoặc vô hiệu các chức năng của panel gọi API riêng của app đó (đổi domain, cấu hình model, đăng nhập Zalo...). Lúc này các API đó không chạy và sẽ timeout.
4. **Hỏi lại trước khi tắt:** hiện thông báo kiểu "Tắt n8n sẽ dừng mọi workflow và webhook. Dữ liệu được giữ nguyên, có thể bật lại bất cứ lúc nào."

## Tham khảo: RAM đo thực tế

Số liệu đo trên VPS 6GB cài đủ 3 app:

| App | RAM khi chạy |
|---|---|
| Hermes | khoảng 1,2–1,4GB (riêng RAG khoảng 0,9GB) |
| n8n | khoảng 1,2–2GB (n8n, worker, NocoDB, Postgres, Redis) |
| OpenClaw | khoảng 0,8–1,3GB |
| Tắt cả 3 app | toàn VPS chỉ còn dùng khoảng 450MB |

## CLI tương đương (SSH vào VPS)

```bash
vps-ai apps              # enabled / disabled
vps-ai disable n8n
vps-ai enable n8n
```
