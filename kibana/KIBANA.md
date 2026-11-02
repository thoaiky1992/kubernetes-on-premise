# Kibana trên ECK on-premise

Kibana CR có hai replica và `elasticsearchRef` tới `search` trong namespace `elasticsearch`. Cùng ECK operator phải quản lý cả hai namespace. ECK tự cấp credential và CA cho kết nối HTTPS tới Elasticsearch.

`storage-class.yaml`, `pv.yaml` và `pvc.yaml` nằm cùng thư mục theo cấu trúc chung của repo. Kibana hiện lưu saved objects trong Elasticsearch nên quy trình cài bình thường không apply `pvc.yaml` và không mount local PV.

## Local PV tùy chọn

Không cần chuẩn bị storage để cài Kibana theo manifest hiện tại. Chỉ khi chủ động apply `kibana/pvc.yaml` để kiểm tra storage, đường dẫn `/srv/k8s-local/kibana` mới phải tồn tại trên `cp1`; không tạo đường dẫn này trên máy local chạy `kubectl`:

```bash
ssh -F /dev/null -t ky@192.168.51.100 \
  'sudo install -d -o 1000 -g 1000 -m 0750 /srv/k8s-local/kibana &&
   stat -c "%u:%g %a %n" /srv/k8s-local/kibana'
```

Với production, mount data disk/filesystem riêng trước rồi mới `chown`; ví dụ lab trên chỉ tạo thư mục trong root filesystem. Nếu pod thử storage báo `FailedMount ... path does not exist`, tạo/mount đường dẫn trên `cp1`; kubelet sẽ tự retry.

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" apply -f kibana/namespace.yaml
kubectl --context "$KUBE_CONTEXT" apply -f kibana/deployment.yaml
kubectl --context "$KUBE_CONTEXT" -n kibana wait \
  --for=jsonpath='{.status.health}'=green kibana/kibana --timeout=15m
kubectl --context "$KUBE_CONTEXT" -n kibana get kibana,pods -o wide
kubectl --context "$KUBE_CONTEXT" -n kibana port-forward svc/kibana-kb-http 5601:5601
```

Mở `https://localhost:5601` qua port-forward trên máy quản trị; chứng chỉ ECK tự ký nên nhập CA tương ứng vào trình duyệt nếu cần xác minh. Service do ECK tự tạo. Muốn mở cho người dùng trên LAN, cài ingress controller và cấu hình DNS/TLS, chính sách truy cập riêng.
