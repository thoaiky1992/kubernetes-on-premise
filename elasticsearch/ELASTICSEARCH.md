# Elasticsearch trên local PV

ECK quản lý 6 pod Elasticsearch, mỗi pod dùng một PV local 50 GiB trên một node khác nhau. Nhãn `topology.kubernetes.io/zone` chia 6 node thành 3 failure domain, 2 node mỗi zone; `zoneAwareness` và pod anti-affinity trong CR dùng các nhãn này. Đọc [README gốc](../README.md) và tạo StorageClass/PV trước khi cài. Local PV không tự di chuyển khi node mất.

## Chuẩn bị đường dẫn local PV

Đường dẫn `/srv/k8s-local/elasticsearch` phải tồn tại trên **cả sáu Kubernetes node**, không phải trên máy local chạy `kubectl`. Với production, gắn một filesystem/data disk riêng 50 GiB hoặc lớn hơn vào đường dẫn này trên từng node, khai báo bằng UUID trong `/etc/fstab`, sau đó xác nhận:

```bash
findmnt /srv/k8s-local/elasticsearch
sudo chown 1000:1000 /srv/k8s-local/elasticsearch
sudo chmod 0750 /srv/k8s-local/elasticsearch
```

Không format hoặc mount thiết bị trước khi xác nhận đó là data disk trống. Xem quy trình chọn thiết bị và tạo filesystem trong [README gốc](../README.md#3-chuẩn-bị-local-pv).

Nếu chỉ thử nghiệm và chấp nhận lưu dữ liệu trên root filesystem, từ máy local có thể tạo thư mục qua SSH trên sáu node:

```bash
for ip in 100 101 102 103 104 105; do
  ssh -F /dev/null -t "ky@192.168.51.$ip" \
    'sudo install -d -o 1000 -g 1000 -m 0750 \
      /srv/k8s-local/elasticsearch &&
     stat -c "%u:%g %a %n" /srv/k8s-local/elasticsearch &&
     df -h /srv/k8s-local/elasticsearch | tail -1'
done
```

Kết quả `stat` phải bắt đầu bằng `1000:1000 750`. Khi chỉ tạo thư mục, `findmnt` không trả kết quả vì đường dẫn không phải mount point riêng. Cách lab này không tạo quota 50 GiB: dữ liệu Elasticsearch dùng trực tiếp root disk và có thể làm node `DiskPressure`. Không triển khai thêm Kafka/Redis trên cùng đĩa 100 GiB.

## Cài đặt

Chạy từ gốc repo, trên máy có `kubectl`, `helm`, `jq`, context đúng và registry có image của Elastic:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"

kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/storage-class.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/pv.yaml

KUBE_CONTEXT="$KUBE_CONTEXT" bash elasticsearch/check.sh

helm repo add elastic https://helm.elastic.co --force-update

helm repo update elastic

helm --kube-context "$KUBE_CONTEXT" upgrade --install elastic-operator elastic/eck-operator \
  --namespace elastic-system --create-namespace --version 3.5.0 \
  -f elasticsearch/eck-values.yaml --wait --timeout 10m

kubectl --context "$KUBE_CONTEXT" wait --for=condition=Established \
  crd/elasticsearches.elasticsearch.k8s.elastic.co --timeout=120s

cp elasticsearch/secret.yaml.example elasticsearch/secret.yaml
chmod 600 elasticsearch/secret.yaml
${EDITOR:-vi} elasticsearch/secret.yaml

kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/role-mapping.yaml
kubectl --context "$KUBE_CONTEXT" apply -f elasticsearch/elasticsearch.yaml
kubectl --context "$KUBE_CONTEXT" -n elasticsearch wait \
  --for=jsonpath='{.status.health}'=green elasticsearch/search --timeout=20m
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pods,pvc -o wide
```

Không commit `secret.yaml`. ECK tạo HTTPS và transport TLS; Secret `search-es-http-certs-public` chứa CA dùng cho app. `pvc.yaml` chỉ dùng thử storage, không áp khi cài bình thường vì ECK tự tạo sáu PVC từ `volumeClaimTemplates`. `check.sh` kiểm tra node/zone và object PV trong Kubernetes nhưng không thể xác nhận đường dẫn trên filesystem của từng node. `vm.max_map_count=1048576` phải được đặt trên từng node hoặc init container `sysctl` hiện có cần quyền privileged.

Nếu lệnh chờ `health=green` đứng lâu, kiểm tra:

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get pods,pvc -o wide
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get events \
  --sort-by=.lastTimestamp | tail -30
```

Lỗi `FailedMount: path "/srv/k8s-local/elasticsearch" does not exist` nghĩa là đường dẫn chưa được chuẩn bị trên node chứa pod. Tạo/mount đường dẫn trên đúng node theo phần trên; kubelet sẽ tự retry nên không cần apply lại PV, PVC hoặc Elasticsearch CR. Có thể nhấn `Ctrl+C` để dừng `kubectl wait` và chạy lại sau khi pod bắt đầu hoạt động; thao tác đó không xóa resource.

## Truy cập và backup

```bash
kubectl --context "$KUBE_CONTEXT" -n elasticsearch get secret search-es-elastic-user \
  -o jsonpath='{.data.elastic}' | base64 --decode
kubectl --context "$KUBE_CONTEXT" -n elasticsearch port-forward svc/search-es-http 9200:9200
```

Chỉ chuyển dữ liệu từ cluster cũ bằng snapshot/restore đã kiểm chứng hoặc quy trình reindex. Snapshot repository phải là kho dùng chung **ngoài** sáu PV dữ liệu (NFS có quyền truy cập trên mọi Elasticsearch pod hoặc S3-compatible object store được cấu hình riêng); không dùng `/usr/share/elasticsearch/data` hay PV của một node làm repository. Cấu hình repository, SLM và thử restore theo [tài liệu Elastic](https://www.elastic.co/docs/deploy-manage/tools/snapshot-and-restore/cloud-on-k8s). Không có AWS credential hay Pod Identity trong manifest này. `Retain` và `DeleteOnScaledownOnly` giữ PVC khi xóa CR; kiểm tra PV/claimRef trước khi tái dùng. Dung lượng local PV không nới tự động bằng cách sửa PVC.
