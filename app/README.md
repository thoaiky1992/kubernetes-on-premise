# Node.js kết nối Elasticsearch và Redis Cluster qua TLS

Thư mục này chứa ứng dụng Node.js mẫu. Ứng dụng kết nối hai backend, mỗi backend một CA riêng, và xác minh chứng chỉ máy chủ trên cả hai. Redis Cluster dùng client cluster để định tuyến theo slot. Mọi log là một dòng JSON, có `trace_id` để nối các dòng của cùng một request.

| Tệp | Mục đích |
| --- | --- |
| `server.js`, `package.json`, `Dockerfile` | Ứng dụng HTTP và ảnh container. |
| `namespace.yaml`, `deployment.yaml` | Namespace và Deployment Kubernetes. |
| `service.yml` | Service `node-api` cho `kubectl port-forward` khi test từ máy cục bộ. |
| `storage-class.yaml`, `pv.yaml`, `pvc.yaml` | Local storage tùy chọn; ứng dụng hiện stateless nên không apply PVC khi cài bình thường. |
| `credentials.env.example` | Mẫu biến môi trường dùng để tạo Secret. |

## Kết nối

| Backend | Cách kết nối | Service trong cluster | CA trong ConfigMap `backend-ca` |
| --- | --- | --- | --- |
| Elasticsearch | HTTPS, xác thực Basic | `search-es-http.elasticsearch.svc:9200` | `elasticsearch-ca.crt` |
| Redis Cluster | TLS tới một node, client đọc topology và định tuyến theo slot | `redis-cluster-leader.redis-cluster.svc:6379` | `redis-cluster-ca.crt` |

Redis Cluster trả về hostname của Pod (không phải IP) trong phản hồi. Hostname này khớp SAN của chứng chỉ Redis, nên client xác minh được chứng chỉ mà không tắt TLS.

## Điều kiện trước khi chạy

- Elasticsearch trong `elasticsearch/elasticsearch.yaml` đã sẵn sàng; ECK tạo Secret `search-es-http-certs-public` với `ca.crt` ở namespace `elasticsearch`.
- Redis Cluster đã sẵn sàng theo [`redis-cluster/README.md`](../redis-cluster/README.md). Secret `redis-cluster-tls` ở namespace `redis-cluster` có `ca.crt`, và Secret `redis-cluster-auth` có khóa `redis-password`.
- Có tài khoản Elasticsearch được cấp quyền phù hợp cho ứng dụng. Có thể dùng `elastic` để thử, sau đó thay bằng tài khoản có quyền tối thiểu.
- Máy triển khai có `kubectl`, Docker, quyền push image tới registry mà cluster kéo được, và `jq` để đọc log.

Các lệnh dưới đây chạy từ **gốc repository**. Đặt context Kubernetes trước để tránh ghi nhầm cluster:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" apply -f app/namespace.yaml
```

Nếu tên Service khác, sửa `REDIS_CLUSTER_HOST` trong `deployment.yaml`. OT Redis Operator tạo Service `<tên>-leader` cho RedisCluster.

## Tạo CA và ConfigMap `backend-ca`

Kubernetes không cho Pod mount Secret từ namespace khác. Sao chép **chỉ chứng chỉ CA công khai**, không sao chép `tls.key`, vào ConfigMap `backend-ca` trong namespace `app`:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get secret search-es-http-certs-public \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/elasticsearch-ca.crt

kubectl --context "$KUBE_CONTEXT" -n redis-cluster get secret redis-cluster-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/redis-cluster-ca.crt

test -s /tmp/elasticsearch-ca.crt && test -s /tmp/redis-cluster-ca.crt

kubectl --context "$KUBE_CONTEXT" -n app create configmap backend-ca \
  --from-file=elasticsearch-ca.crt=/tmp/elasticsearch-ca.crt \
  --from-file=redis-cluster-ca.crt=/tmp/redis-cluster-ca.crt \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -

# Xem thông tin secret backend-ca
kubectl --context "$KUBE_CONTEXT" -n app get configmap backend-ca -o yaml

kubectl --context "$KUBE_CONTEXT" -n app get configmap backend-ca -o jsonpath='{.data}'

kubectl --context "$KUBE_CONTEXT" -n app get configmap backend-ca -o jsonpath='{.data.elasticsearch-ca\.crt}'

kubectl --context "$KUBE_CONTEXT" -n app get configmap backend-ca -o jsonpath='{.data.redis-cluster-ca\.crt}'
```

Secret `redis-cluster-tls` có `ca.crt` vì cert-manager ghi CA của `redis-cluster-ca` vào đó. Chứng chỉ lá của Redis Cluster gia hạn mỗi 90 ngày nhưng CA không đổi, nên ConfigMap không cần cập nhật khi gia hạn lá.

## Tạo Secret chứa mật khẩu

Không commit `app/credentials.env` vì tệp này chứa mật khẩu; thư mục `app/` đã có `.gitignore` cho tệp này.

```bash
cp app/credentials.env.example app/credentials.env
# Sửa app/credentials.env:
#   ELASTICSEARCH_USERNAME, ELASTICSEARCH_PASSWORD
#   REDIS_CLUSTER_PASSWORD   = giá trị khóa redis-password của Secret redis-cluster-auth
kubectl --context "$KUBE_CONTEXT" -n app create secret generic backend-credentials \
  --from-env-file=app/credentials.env \
  --dry-run=client -o yaml | kubectl --context "$KUBE_CONTEXT" apply -f -
```

Để tránh gõ sai mật khẩu, lấy trực tiếp từ cluster:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get secret redis-cluster-auth \
  -o jsonpath='{.data.redis-password}' | base64 --decode; echo
```

Ứng dụng đọc cấu hình khi khởi động. Nếu đổi mật khẩu hoặc CA, cập nhật Secret/ConfigMap rồi chạy `kubectl -n app rollout restart deployment/node-api`. Không dùng `rejectUnauthorized: false` hoặc bỏ qua xác minh hostname.

## Build và triển khai

```bash
docker build -t thoaiky1992/node-api:1.0.0 app
docker push thoaiky1992/node-api:1.0.0
```

Sửa `image` trong `app/deployment.yaml` thành image đã push. Nếu registry riêng tư, tạo `imagePullSecret` trong namespace `app` và gắn vào Pod. Sau đó:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f app/service.yml
kubectl --context "$KUBE_CONTEXT" apply -f app/deployment.yaml
kubectl --context "$KUBE_CONTEXT" -n app rollout status deployment/node-api
```

## Test từ máy cục bộ

Ứng dụng chạy trong cluster, máy cục bộ truy cập qua `kubectl port-forward`. Cách này bắt buộc vì Redis Cluster trả về hostname nội bộ của Pod, máy cục bộ không phân giải được các hostname đó.

### 1. Gọi HTTP của ứng dụng

```bash
kubectl --context "$KUBE_CONTEXT" -n app port-forward svc/node-api 3000:3000
```

Ở terminal khác:

```bash
curl -i http://localhost:3000/healthz
curl -i http://localhost:3000/readyz
curl -s http://localhost:3000/api/check | jq .
```

Gửi một `traceparent` do bạn chọn để tự gán `trace_id`:

```bash
TRACE_ID="$(openssl rand -hex 16)"
curl -s -H "traceparent: 00-${TRACE_ID}-$(openssl rand -hex 8)-01" http://localhost:3000/api/check | jq .
```

Mỗi phản hồi có header `x-trace-id` trùng với `trace_id` trong log.

### 2. Xem trace log theo `trace_id`

```bash
kubectl --context "$KUBE_CONTEXT" -n app logs deploy/node-api --all-pods=true \
  | jq -c --arg t "$TRACE_ID" 'select(.trace_id == $t)'
```

Các dòng `backend.check` cho thấy từng backend trả lời trong bao nhiêu mili giây. Trace ID cũng được gửi sang Elasticsearch qua header `X-Opaque-Id`, nên có thể tìm cùng ID trong log của Elasticsearch.

### 3. Forward từng backend để kiểm tra trực tiếp

Các lệnh này kiểm tra TLS và mật khẩu của từng backend, không đi qua ứng dụng. Với `curl --resolve` và `redis-cli --sni`, tên miền trong chứng chỉ vẫn được xác minh, chỉ địa chỉ được trỏ về `127.0.0.1`.

Elasticsearch:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch port-forward svc/search-es-http 9200:9200
# Terminal khác:
curl --cacert /tmp/elasticsearch-ca.crt \
  --resolve search-es-http.elasticsearch.svc:9200:127.0.0.1 \
  -u "$ELASTICSEARCH_USERNAME:$ELASTICSEARCH_PASSWORD" \
  https://search-es-http.elasticsearch.svc:9200
```

Redis Cluster:

```bash
kubectl --context "$KUBE_CONTEXT" -n redis-cluster port-forward svc/redis-cluster-leader 6379:6379
# Terminal khác:
redis-cli --tls --cacert /tmp/redis-cluster-ca.crt \
  --sni redis-cluster-leader.redis-cluster.svc \
  -h 127.0.0.1 -p 6379 --no-auth-warning -a "$REDIS_CLUSTER_PASSWORD" \
  CLUSTER INFO
```

Lệnh `CLUSTER INFO` và `PING` chạy được qua port-forward. Với key thuộc slot của node khác, `MOVED` trả về hostname nội bộ, nên thao tác đó chỉ thực hiện được trong cluster.

### Chạy `npm start` ngoài cluster

`npm start` trên máy cục bộ không được hỗ trợ đầy đủ vì cùng lý do hostname nội bộ ở trên. Kết nối tới Elasticsearch vẫn kiểm tra được bằng các lệnh ở mục 3, nhưng các node Cluster thì không. Khi cần test đầy đủ, build image và chạy trong cluster.

## Endpoint

| Method và đường dẫn | Trạng thái | Mô tả |
| --- | --- | --- |
| `GET /healthz` | 200 | Tiến trình HTTP còn chạy. Dùng cho liveness probe. |
| `GET /readyz` | 200 hoặc 503 | Trạng thái đã lưu của cả ba backend, không gửi lệnh mới. Dùng cho readiness probe. |
| `GET /api/check` | 200 hoặc 503 | Gửi PING/`ping()` tới cả ba backend ngay lúc gọi, trả về độ trễ và lỗi của từng backend. |
| `GET /api/stress/cpu` | 202, 400 hoặc 409 | Tạo tải CPU trong nền. Tham số `workers` (1–4) và `duration` (giây, tối đa 300). |
| `GET /api/stress/memory` | 202, 400 hoặc 409 | Cấp phát và giữ RAM trong nền. Tham số `memory_mb` (0–1024) và `duration` (giây, tối đa 300). |

Ví dụ `GET /api/check` khi Redis Cluster lỗi:

```json
{
  "ok": false,
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "services": {
    "elasticsearch": { "ok": true, "checked_at": "2026-10-29T05:50:01.000Z", "duration_ms": 12.4 },
    "redis_cluster": {
      "ok": false,
      "error": { "name": "Error", "message": "client is not connected" },
      "checked_at": "2026-10-29T05:50:01.003Z",
      "duration_ms": 0.05
    }
  }
}
```

Mọi method khác `GET` trả 405, đường dẫn không có trả 404. Cả hai đều có `trace_id` trong body và header `x-trace-id`.

## Stress test CPU và RAM

Hai API này dùng để kiểm tra giới hạn tài nguyên và hành vi OOM hoặc autoscaling của Pod. Chúng không kiểm tra backend.

| Tham số | API | Mặc định | Giới hạn | Ý nghĩa |
| --- | --- | --- | --- | --- |
| `workers` | `/api/stress/cpu` | 1 | 0–4 | Số worker thread chạy vòng lặp tính toán. Event loop vẫn xử lý probe. |
| `memory_mb` | `/api/stress/memory` | 128 | 0–1024 | Dung lượng RAM cấp phát và ghi đầy, tính vào RSS. |
| `duration` | cả hai | 30 | 0–300 | Thời gian chạy, tính bằng giây. |

Mỗi loại chỉ có một job tại một thời điểm, nhưng CPU và RAM có thể chạy đồng thời. Request hợp lệ trả `202` ngay với thông tin job, còn job chạy nền:

```bash
kubectl --context "$KUBE_CONTEXT" -n app port-forward svc/node-api 3000:3000
# Terminal khác:
curl -s "http://localhost:3000/api/stress/cpu?workers=2&duration=60" | jq .
curl -s "http://localhost:3000/api/stress/memory?memory_mb=256&duration=60" | jq .
```

Phản hồi mẫu:

```json
{
  "trace_id": "0af7651916cd43dd8448eb211c80319c",
  "job": {
    "trace_id": "0af7651916cd43dd8448eb211c80319c",
    "started_at": "2026-10-29T06:00:00.000Z",
    "workers": 2,
    "duration_seconds": 60
  }
}
```

Lỗi:

- `400` khi tham số không phải số nguyên hoặc vượt giới hạn. Nội dung lỗi nêu tên tham số.
- `409` khi cùng loại đang chạy. Trường `job` trong phản hồi là job hiện tại.

Theo dõi tiến trình qua log `stress.started` và `stress.finished`, có trường `kind` là `cpu` hoặc `memory`.

Lưu ý:

- Đặt `memory_mb` thấp hơn giới hạn memory của container trong `deployment.yaml`. Vượt giới hạn sẽ làm Pod bị OOMKilled và khởi động lại. Kiểm tra giới hạn bằng `kubectl --context "$KUBE_CONTEXT" -n app get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].resources}'`.
- Hai API không có xác thực. Chỉ dùng trong môi trường test, và gỡ hoặc hạn chế truy cập trước khi đưa ứng dụng ra ngoài.
- Không có API dừng job. Job tự kết thúc khi hết `duration`.

## Log JSON

Mỗi dòng là một object JSON trên stdout (`warn` và `error` ra stderr). Các trường chung:

| Trường | Ý nghĩa |
| --- | --- |
| `ts` | Thời điểm ghi log, ISO 8601 UTC. |
| `level` | `debug`, `info`, `warn` hoặc `error`. |
| `service` | Luôn là `node-api`. |
| `event` | Tên sự kiện, xem bảng dưới. |
| `trace_id` | ID 32 ký tự hex. Lấy từ `traceparent` của request, hoặc tự sinh cho lần kiểm tra định kỳ. |
| `backend` | `elasticsearch` hoặc `redis_cluster`. |
| `duration_ms` | Thời gian của thao tác, tính bằng mili giây. |
| `error` | Object có `name`, `message` và `code` (nếu có). |

Ví dụ:

```json
{"ts":"2026-10-29T05:50:01.002Z","level":"info","service":"node-api","event":"backend.check","backend":"redis_cluster","trace_id":"0af7651916cd43dd8448eb211c80319c","ok":true,"duration_ms":3.1}
{"ts":"2026-10-29T05:50:01.003Z","level":"error","service":"node-api","event":"backend.check","backend":"redis_cluster","trace_id":"0af7651916cd43dd8448eb211c80319c","ok":false,"duration_ms":0.05,"error":{"name":"Error","message":"client is not connected"}}
{"ts":"2026-10-29T05:50:01.004Z","level":"info","service":"node-api","event":"http.request","trace_id":"0af7651916cd43dd8448eb211c80319c","method":"GET","path":"/api/check","status":503,"duration_ms":14.2}
```

| Event | Level | Khi nào |
| --- | --- | --- |
| `config.missing_env`, `config.invalid_url`, `config.invalid_port`, `config.ca_unreadable` | error | Cấu hình sai khi khởi động. Tiến trình thoát với mã 1. |
| `app.listening` | info | HTTP server đã nghe trên `PORT`. |
| `config.backends` | info | Khi khởi động, liệt kê backend nào được bật (`enabled`) và bị tắt (`disabled`). |
| `backend.connected` | info | Cluster client sẵn sàng. |
| `backend.check` | info hoặc error | Mỗi lần kiểm tra một backend, kèm `duration_ms` và `ok`. |
| `backend.up`, `backend.down` | info hoặc error | Chỉ ghi khi trạng thái đổi. |
| `redis_cluster.error` | error | Lỗi từ client Redis. |
| `http.request` | info (`debug` cho `/healthz`, `/readyz`) | Mỗi request HTTP, kèm `status` và `duration_ms`. |
| `library.log` | info, warn hoặc error | Thư viện Redis gọi `console.log`; nội dung nằm trong `message`. |
| `app.shutdown` | info | Nhận SIGTERM hoặc SIGINT. |
| `stress.started`, `stress.finished` | info | Bắt đầu và kết thúc một job stress, có trường `kind` (`cpu` hoặc `memory`). |
| `stress.worker_error` | error | Worker thread của stress CPU gặp lỗi. |
| `process.uncaught_exception`, `process.unhandled_rejection` | error | Lỗi không được bắt. Tiến trình thoát với mã 1. |

Lọc log lỗi:

```bash
kubectl --context "$KUBE_CONTEXT" -n app logs deploy/node-api --all-pods=true --prefix=true \
  | jq -c 'select(.level == "error")'
```

Biến `LOG_LEVEL` đặt mức tối thiểu (`debug`, `info`, `warn`, `error`). Mặc định là `info`.

## Biến môi trường

| Biến | Bắt buộc | Ý nghĩa |
| --- | --- | --- |
| `PORT` | Không | Cổng HTTP, mặc định `3000`. |
| `LOG_LEVEL` | Không | Mức log, mặc định `info`. |
| `ELASTICSEARCH_ENABLED` | Không | `true` thì kết nối Elasticsearch. Mọi giá trị khác (kể cả thiếu) là tắt. |
| `REDIS_CLUSTER_ENABLED` | Không | `true` thì kết nối Redis Cluster. Mọi giá trị khác là tắt. |
| `ELASTICSEARCH_URL` | Khi bật | Phải bắt đầu bằng `https://`. |
| `ELASTICSEARCH_USERNAME`, `ELASTICSEARCH_PASSWORD` | Khi bật | Tài khoản Elasticsearch (từ Secret `backend-credentials`). |
| `ELASTICSEARCH_CA_FILE` | Khi bật | Đường dẫn CA của Elasticsearch trong container. |
| `REDIS_CLUSTER_HOST`, `REDIS_CLUSTER_PORT` | Khi bật | Root node của Redis Cluster, cổng `6379`. |
| `REDIS_CLUSTER_PASSWORD` | Khi bật | Mật khẩu của Redis Cluster (Secret `redis-cluster-auth`). |
| `REDIS_CLUSTER_CA_FILE` | Khi bật | CA của Redis Cluster trong container. |

Backend bị tắt không tạo kết nối và không được tính vào `/readyz` hoặc `/api/check`. Thiếu biến bắt buộc của backend đang bật, sai định dạng URL/cổng, hoặc không đọc được CA thì tiến trình ghi log JSON rồi thoát với mã 1.

## Gia hạn chứng chỉ

- Khi ECK thay CA của Elasticsearch, hoặc CA `redis-cluster-ca` được xoay vòng: tạo lại ConfigMap `backend-ca` từ CA mới, rồi chạy `kubectl --context "$KUBE_CONTEXT" -n app rollout restart deployment/node-api`.
- Khi chỉ chứng chỉ lá được gia hạn dưới cùng CA, client vẫn tin cậy CA hiện tại, không cần làm gì trong app. Chứng chỉ lá của Redis Cluster được cert-manager gia hạn định kỳ; xem thêm quy trình khởi động lại trong các README của Redis.

Tham khảo: [Elastic JavaScript client TLS](https://www.elastic.co/docs/reference/elasticsearch/clients/javascript/connecting), [node-redis Cluster](https://github.com/redis/node-redis/blob/master/docs/clustering.md), [node-redis TLS](https://github.com/redis/node-redis/blob/master/docs/client-configuration.md).
