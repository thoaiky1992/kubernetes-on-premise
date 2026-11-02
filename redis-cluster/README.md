# Redis Cluster trên local PV

OT Redis Operator quản lý 3 leader + 3 follower, có TLS cho client, replication và cluster bus. Mỗi pod dùng **hai PVC**: dữ liệu 20 GiB và `nodes.conf` 1 GiB; PV local gắn với đúng một node. Nhãn zone phải là ba failure domain thật, hai node mỗi zone. Đọc [README gốc](../README.md) và tạo PV trước khi cài.

## Chuẩn bị đường dẫn local PV

`/srv/k8s-local/redis-data` và `/srv/k8s-local/redis-conf` phải tồn tại trên cả sáu Kubernetes node. `/srv/k8s-local/redis-backup` chỉ tồn tại trên `cp1`. Các đường dẫn này nằm trên node, không nằm trên máy local chạy `kubectl`. Với production, mount filesystem/data disk riêng vào từng đường dẫn và xác nhận bằng `findmnt`.

Nếu chỉ thử nghiệm trên root disk, tạo các thư mục qua SSH:

```bash
for ip in 100 101 102 103 104 105; do
  ssh -F /dev/null -t "ky@192.168.51.$ip" \
    'sudo install -d -o 1000 -g 1000 -m 0750 \
       /srv/k8s-local/redis-data /srv/k8s-local/redis-conf &&
     stat -c "%u:%g %a %n" \
       /srv/k8s-local/redis-data /srv/k8s-local/redis-conf'
done

ssh -F /dev/null -t ky@192.168.51.100 \
  'sudo install -d -o 999 -g 999 -m 0750 /srv/k8s-local/redis-backup &&
   stat -c "%u:%g %a %n" /srv/k8s-local/redis-backup'
```

Redis pod chạy UID/GID `1000:1000`; backup CronJob chạy `999:999`. Dung lượng PV không tạo quota cho thư mục. Nếu pod đứng lâu, xem event; lỗi `FailedMount ... path does not exist` yêu cầu tạo/mount path trên đúng node, sau đó kubelet tự retry.

## Cài cert-manager và Redis operator

Chạy từ root repo, đặt context rõ ràng:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"

kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/storage-class.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/pv.yaml

helm --kube-context "$KUBE_CONTEXT" upgrade --install cert-manager \
  oci://quay.io/jetstack/charts/cert-manager \
  --version v1.21.2 --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 10m

helm --kube-context "$KUBE_CONTEXT" upgrade --install redis-cluster-operator \
  oci://ghcr.io/ot-container-kit/charts/redis-operator \
  --version 0.27.0 --namespace redis-cluster-system \
  -f redis-cluster/operator-values.yaml --wait --timeout 10m

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/redisclusters.redis.redis.opstreelabs.in crd/certificates.cert-manager.io --timeout=120s
```

Nếu operator/CRD đã tồn tại, kiểm tra release sở hữu trước khi cài/nâng cấp. Helm upgrade không tự nâng cấp CRD.

## Tạo TLS, Secret và cluster

Build/push image `redis-cluster/images/redis-cluster/Dockerfile` tới registry nội bộ hoặc registry mà cả sáu node kéo được; sửa `spec.kubernetesConfig.image` trong `redis-cluster.yaml`. Image riêng bắt buộc để announce FQDN khớp SAN của chứng chỉ. Tạo mật khẩu mạnh trong file local:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/certificate.yaml

kubectl --context "$KUBE_CONTEXT" -n redis-cluster wait \
  --for=condition=Ready certificate/redis-cluster-ca certificate/redis-cluster-tls --timeout=5m

cp redis-cluster/secret.yaml.example redis-cluster/secret.yaml
chmod 600 redis-cluster/secret.yaml
${EDITOR:-vi} redis-cluster/secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/redis-cluster-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/redis-cluster.yaml

kubectl --context "$KUBE_CONTEXT" -n redis-cluster get pods,pvc -o wide
KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
```

Redis Operator tự tạo 12 PVC dữ liệu và `nodes.conf` từ `redis-cluster.yaml`; `redis-cluster/pvc.yaml` chỉ khai báo PVC backup. Không commit `secret.yaml`. Script kiểm tra 16384 slot, 3 master và replica khác zone. Nếu Pod Pending, kiểm tra các PV `local-redis-data`/`local-redis-conf` và node affinity của cả hai PVC. `keepAfterDelete` cùng `Retain` giữ dữ liệu khi xóa CR/PVC; không tái dùng PV chưa kiểm tra `claimRef` và dữ liệu.

## Phân bố AZ

Affinity trong manifest bảo đảm mỗi zone có một pod leader và một pod follower, nhưng scheduler không biết follower Redis đang replicate master nào. Vì vậy cluster có thể hoạt động nhưng một master/replica cùng zone, hoặc thao tác `CLUSTER REPLICATE` dở dang làm một master có hai replica và master khác không có replica.

Script sau đọc topology Redis và nhãn zone, yêu cầu đúng 3 zone với 1 master + 1 replica mỗi zone, rồi tìm phép ghép replica vào master khác zone. Script ưu tiên giữ các cặp đang đúng để giảm full sync và mặc định chỉ in kế hoạch:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
bash redis-cluster/ensure-zone-replication.sh
```

Kiểm tra bảng kế hoạch, thực hiện trong maintenance window rồi kiểm tra lại:

```bash
bash redis-cluster/ensure-zone-replication.sh --apply
KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
```

Mỗi thay đổi có thể làm replica full sync và tạm thời khiến một master thiếu replica. Script thực hiện tuần tự, chờ replica đồng bộ xong trước bước kế tiếp. Nếu một zone không có đúng 1 master và 1 replica, script dừng và không tự promote/failover; phải sửa scheduling hoặc role distribution trước để tránh mất dữ liệu. Dùng `--apply --yes` chỉ cho automation đã được kiểm soát.

## Backup và phục hồi

CronJob tạo RDB của từng master, kiểm tra `redis-check-rdb`, ghi `metadata.json`, `SHA256SUMS` và `_SUCCESS` sau cùng vào PVC `redis-cluster-backup` (local PV 50 GiB trên `cp1`). Build/push image backup từ `redis-cluster/images/redis-cluster-backup/`, sửa tag trong CronJob nếu cần:

```bash
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/pvc.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/backup-configmap.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redis-cluster/backup-cronjob.yaml
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get cronjob,job,pvc
```

**Sao chép `/archive/redis-cluster/` ra lưu trữ ngoài cluster** bằng cơ chế riêng (ví dụ đồng bộ từ mountpoint `/srv/k8s-local/redis-backup` trên `cp1` sang NAS/offsite), và chỉ coi thư mục có `_SUCCESS` là hoàn chỉnh. Kiểm tra SHA256SUMS và thử restore trên cluster thử nghiệm. Nếu `cp1`/ổ local mất, bản backup trên PVC này cũng mất. Khi khôi phục, tạo cluster đích sạch với PV mới; nạp từng `dump.rdb` vào Redis 7.0.15 tạm, dùng `dump_to_resp.py` trong image restore **đọc Redis tạm** để tạo lệnh RESP, rồi pipe vào master đích theo metadata và xác nhận slot/replica. Script này không đọc trực tiếp file RDB. Không copy `nodes.conf` giữa hai cluster độc lập. Migration từ EBS/S3 cũ cần xuất backup trước và restore riêng; manifest không tự di chuyển dữ liệu.
