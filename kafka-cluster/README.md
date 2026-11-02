# Kafka/Strimzi trên 6 node on-premise

KafkaNodePool có 6 pod broker/controller KRaft, mỗi pod dùng một local PV 50 GiB và chạy trên một host riêng. Rack/zone: 2 node mỗi `rack-a`, `rack-b`, `rack-c`. Topic mặc định 3 replica, `min.insync.replicas=2`. Mất node lưu local PV sẽ làm PVC tương ứng không thể chạy ở node khác; cần quy trình phục hồi broker và backup ngoài cluster.

## Chuẩn bị đường dẫn local PV

`/srv/k8s-local/kafka` phải tồn tại trên cả sáu Kubernetes node, không phải trên máy local chạy `kubectl`. Với production, mount data disk riêng vào đường dẫn này, khai báo bằng UUID trong `/etc/fstab`, rồi xác nhận bằng `findmnt`.

Nếu chỉ thử nghiệm trên root disk, tạo thư mục từ máy local; image Strimzi chạy bằng UID `1001`, group `0`:

```bash
for ip in 100 101 102 103 104 105; do
  ssh -F /dev/null -t "ky@192.168.51.$ip" \
    'sudo install -d -o 1001 -g 0 -m 0770 /srv/k8s-local/kafka &&
     stat -c "%u:%g %a %n" /srv/k8s-local/kafka'
done
```

Kết quả phải bắt đầu bằng `1001:0 770`. Dung lượng PV 50 GiB không tạo quota cho thư mục; không chạy Kafka cùng Elasticsearch/Redis trên root disk 100 GiB. Nếu pod đứng lâu, kiểm tra `kubectl -n kafka get events --sort-by=.lastTimestamp | tail -30`; lỗi `FailedMount ... path does not exist` yêu cầu tạo/mount đúng đường dẫn trên node chứa pod.

## Cài operator và Kafka

Đọc [README gốc](../README.md), tạo PV và gán zone trước. Từ root repo:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/storage-class.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/pv.yaml
KUBE_CONTEXT="$KUBE_CONTEXT" bash kafka-cluster/check.sh
helm --kube-context "$KUBE_CONTEXT" upgrade --install strimzi-kafka-operator \
  oci://quay.io/strimzi-helm/strimzi-kafka-operator \
  --version 1.3.0 --namespace kafka-system --create-namespace \
  -f kafka-cluster/strimzi-values.yaml --wait --timeout 10m
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/kafkas.kafka.strimzi.io crd/kafkanodepools.kafka.strimzi.io --timeout=120s
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-nodepool.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka wait kafka/kafka-cluster \
  --for=condition=Ready --timeout=20m
kubectl --context "$KUBE_CONTEXT" -n kafka get pods,pvc -o wide
```

Strimzi tự tạo sáu PVC từ `kafka-nodepool.yaml`; `pvc.yaml` chỉ dùng kiểm tra và không áp trong quy trình cài bình thường. Nếu PVC Pending, kiểm tra PV `local-kafka`, mountpoint và `nodeAffinity`. Helm không tự nâng CRD khi nâng chart; xem tài liệu Strimzi trước khi đổi phiên bản.

## Kafka Connect và CDC PostgreSQL

Build `kafka-cluster/images/kafka-connect-postgres/Dockerfile`, push image vào registry mà sáu node truy cập được, rồi sửa `spec.image` trong `kafka-connect.yaml`. PostgreSQL chạy trên LAN do bạn quản lý, bật `wal_level=logical`, có user replication và chứng chỉ TLS có SAN khớp hostname trong connector. `sslmode: verify-full` yêu cầu CA phù hợp trong image/truststore; không hạ mức xác minh để bỏ lỗi chứng chỉ. Tạo Secret `postgres-cdc-credentials` từ file properties không commit:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-connect-user.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka wait kafkauser/kafka-connect --for=condition=Ready --timeout=5m
kubectl --context "$KUBE_CONTEXT" -n kafka create secret generic postgres-cdc-credentials \
  --from-file=postgres.properties=/path/to/postgres.properties
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-topics-connect.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kafka-cluster/kafka-connect.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka wait kafkaconnect/kafka-connect --for=condition=Ready --timeout=20m
```

Sao chép `kafka-connector-postgres.example.yaml` sang file local, thay placeholder host/database/table và áp dụng:

```bash
cp kafka-cluster/kafka-connector-postgres.example.yaml /tmp/postgres-cdc.yaml
${EDITOR:-vi} /tmp/postgres-cdc.yaml
kubectl --context "$KUBE_CONTEXT" apply -f /tmp/postgres-cdc.yaml
kubectl --context "$KUBE_CONTEXT" -n kafka get kafkaconnector postgres-cdc
```

Tạo replication slot/publication theo quyền PostgreSQL trước khi chạy. `order-service-topic.yaml` là topic ví dụ, chỉ apply khi cần. Theo dõi lag, dung lượng local PV, consumer offset và thực hiện backup/restore Kafka ngoài cluster.
