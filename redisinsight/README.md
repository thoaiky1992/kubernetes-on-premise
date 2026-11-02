# RedisInsight trên on-premise

RedisInsight dùng một PVC local 5 GiB trên `cp1`, kết nối Redis Cluster qua TLS. Service là `ClusterIP`; chỉ truy cập qua port-forward của người quản trị. `RI_ENCRYPTION_KEY` phải được giữ cùng backup SQLite.

## Chuẩn bị đường dẫn local PV

`/srv/k8s-local/redisinsight` phải tồn tại trên `cp1`, không phải trên máy local chạy `kubectl`. Với production, mount filesystem/data disk riêng vào đường dẫn này. Nếu chỉ thử nghiệm trên root disk:

```bash
ssh -F /dev/null -t ky@192.168.51.100 \
  'sudo install -d -o 1000 -g 1000 -m 0750 /srv/k8s-local/redisinsight &&
   stat -c "%u:%g %a %n" /srv/k8s-local/redisinsight'
```

Kết quả phải bắt đầu bằng `1000:1000 750`. Nếu pod đứng ở `ContainerCreating`, kiểm tra `kubectl -n redisinsight get events --sort-by=.lastTimestamp | tail -30`; lỗi `FailedMount ... path does not exist` yêu cầu tạo/mount path trên `cp1`, sau đó kubelet tự retry.

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
cp redisinsight/secret.yaml.example redisinsight/secret.yaml
chmod 600 redisinsight/secret.yaml
openssl rand -base64 48
${EDITOR:-vi} redisinsight/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/storage-class.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/pv.yaml
kubectl --context "$KUBE_CONTEXT" -n redis-cluster get secret redis-cluster-tls \
  -o jsonpath='{.data.ca\.crt}' | base64 --decode > /tmp/redis-cluster-ca.crt
kubectl --context "$KUBE_CONTEXT" -n redisinsight create configmap redis-cluster-ca \
  --from-file=ca.crt=/tmp/redis-cluster-ca.crt --dry-run=client -o yaml \
  | kubectl --context "$KUBE_CONTEXT" apply -f -
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/secret.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/pvc.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/deployment.yaml
kubectl --context "$KUBE_CONTEXT" apply -f redisinsight/service.yaml
kubectl --context "$KUBE_CONTEXT" -n redisinsight rollout status deploy/redisinsight
kubectl --context "$KUBE_CONTEXT" -n redisinsight port-forward svc/redisinsight 5540:5540
```

Mở `http://localhost:5540` trên cùng máy; không mở cổng này trực tiếp ra mạng vì RedisInsight không có lớp xác thực riêng trong manifest. Trong giao diện, nhập seed `redis-cluster-leader.redis-cluster.svc.cluster.local:6379`, bật TLS, dùng CA `redis-cluster-ca.crt` và mật khẩu từ Secret `redis-cluster-auth`. Nếu PVC Pending, kiểm tra local PV `local-redisinsight` trên `cp1`. Không commit `secret.yaml` và lưu khóa mã hóa trong secret manager.
