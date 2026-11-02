# Kubernetes on-premise: 6 node với local PV

Repo triển khai Elasticsearch/ECK, Redis Cluster, Kafka/Strimzi, Kibana, RedisInsight và ứng dụng Node.js trên **6 máy Linux**. `cp1..cp3` chạy control plane + stacked etcd, `wk1..wk3` là worker. Cả sáu node đều nhận workload vì Elasticsearch và Kafka có sáu pod, mỗi pod trên một host. Cụm hiện dùng Ubuntu 26.04, Kubernetes **1.34.13**, containerd **2.2.2**, Helm **4.3.1**, Cilium **1.20.4** và kube-vip **1.2.4**. Điều chỉnh phiên bản theo ma trận tương thích của các operator trước khi nâng cấp.

| IP | Hostname | Vai trò | Zone |
| --- | --- | --- | --- |
| `192.168.51.100` | `cp1` | control plane, etcd | `rack-a` |
| `192.168.51.101` | `cp2` | control plane, etcd | `rack-b` |
| `192.168.51.102` | `cp3` | control plane, etcd | `rack-c` |
| `192.168.51.103` | `wk1` | worker | `rack-a` |
| `192.168.51.104` | `wk2` | worker | `rack-b` |
| `192.168.51.105` | `wk3` | worker | `rack-c` |

## Trạng thái triển khai (2026-11-04)

- [x] Đổi hostname, tạo machine ID riêng và khai báo `/etc/hosts` trên 6 máy.
- [x] Tắt swap, nạp kernel module/sysctl, cài và cấu hình containerd.
- [x] Cài kubeadm/kubelet/kubectl 1.34.13; tạo 3 control plane + stacked etcd và join 3 worker.
- [x] Cài Cilium 1.20.4; Cilium `6/6`, Cilium Operator `2/2`, CoreDNS `2/2`.
- [x] Cài metrics-server 0.9.1; kubelet trên cả 6 node dùng serving certificate do Kubernetes CA ký và Metrics API hoạt động.
- [x] Cả 6 node `Ready`, không còn taint control-plane và đã gán `rack-a/b/c`.
- [x] Cài kube-vip 1.2.4 trên `cp1..cp3`; `k8s-api` trỏ tới VIP `192.168.51.99`. Đã kiểm tra failover từ `cp3` sang `cp1` thành công.
- [ ] Bổ sung đĩa local, tạo mount point, apply StorageClass/PV và triển khai workload.

Mỗi VM hiện chỉ có khoảng 2 vCPU, 7.2 GiB RAM và một đĩa hệ thống 100 GiB. Không apply các PV/workload của repo ở cấu hình này: Elasticsearch 50 GiB + Kafka 50 GiB + Redis 21 GiB đã là 121 GiB mỗi node; `cp1` cần thêm Redis backup 50 GiB và RedisInsight 5 GiB, tổng 176 GiB chưa kể hai PV kiểm tra tùy chọn. Cần nâng CPU/RAM và gắn đĩa dữ liệu riêng trước khi tiếp tục mục 3.

`rack-a/b/c` phải là **ba miền lỗi vật lý độc lập** (nguồn điện, switch, tủ rack); chỉ gán nhãn khác nhau trên cùng hạ tầng không tạo HA. Bố trí CPU/RAM và đĩa theo tải thật. Cấu hình production nên bắt đầu từ khoảng 8 vCPU, 32 GiB RAM và đĩa dữ liệu riêng có đủ dung lượng dự phòng **mỗi node**. Dung lượng khai báo của local PV không áp hạn mức lên thư mục: dùng phân vùng/filesystem riêng hoặc quota và giám sát đĩa.

## 1. Chuẩn bị mạng, hostname và máy

- Sáu IP phải tĩnh, đồng bộ thời gian, truy cập được registry và kho gói. API dùng `k8s-api:6443` tại VIP `192.168.51.99`; IP này phải được giữ riêng, không cấp qua DHCP hoặc gán cho thiết bị khác. Kube-vip quảng bá VIP bằng ARP từ một trong ba control-plane và tự chuyển leader khi node lỗi. VIP không phải node Kubernetes thứ bảy. Ba control-plane phải cùng Layer 2/VLAN và hạ tầng mạng phải cho phép gratuitous ARP.
- Mở lưu lượng giữa các node theo [cổng Kubernetes](https://kubernetes.io/docs/reference/networking/ports-and-protocols/), Cilium (bao gồm VXLAN UDP 8472 nếu dùng encapsulation mặc định), DNS, và từ máy quản trị tới API 6443. Pod CIDR `10.244.0.0/16` và Service CIDR mặc định không được chồng mạng LAN/VPN.

Đổi hostname trên từng máy theo bảng inventory. Ví dụ trên máy `192.168.51.100`:

```bash
sudo hostnamectl set-hostname cp1
echo 'preserve_hostname: true' | sudo tee /etc/cloud/cloud.cfg.d/99-preserve-hostname.cfg
```

Thực hiện tương tự với `cp2`, `cp3`, `wk1`, `wk2`, `wk3`, sau đó thêm cùng một block trên **cả sáu máy**:

```text
# BEGIN K8S CLUSTER
192.168.51.99 k8s-api
192.168.51.100 cp1
192.168.51.101 cp2
192.168.51.102 cp3
192.168.51.103 wk1
192.168.51.104 wk2
192.168.51.105 wk3
# END K8S CLUSTER
```

Block trên hiện đã được thêm vào `/etc/hosts` của cả sáu node. Thêm mapping tương tự trên máy quản trị nếu mang kubeconfig ra ngoài `cp1`, hoặc tạo DNS nội bộ trỏ `k8s-api` tới `192.168.51.99`. Bản sao trước khi chuyển VIP trên các node nằm tại `/etc/hosts.pre-kube-vip-20261103`. Nếu các VM được clone từ cùng một image, xác nhận `cat /etc/machine-id` khác nhau. Chỉ trước khi chạy `kubeadm`, tạo lại ID trên node bị trùng:

```bash
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo systemd-machine-id-setup
sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id
```

Trên **cả sáu máy**, chạy:

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab
cat <<'CONF' | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
CONF
sudo modprobe overlay
sudo modprobe br_netfilter
cat <<'CONF' | sudo tee /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
CONF
sudo sysctl --system
sudo apt-get update
sudo apt-get install -y containerd ca-certificates curl gpg
sudo install -d /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml >/dev/null
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
sudo systemctl restart containerd
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.34/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.34/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

Nếu máy có nhiều interface, đặt IP đúng của từng node trong `/etc/default/kubelet`, ví dụ trên `cp1`: `KUBELET_EXTRA_ARGS=--node-ip=192.168.51.100`, rồi restart kubelet.

Nếu `containerd` 2.x, đối chiếu đường dẫn cấu hình `SystemdCgroup` theo [tài liệu container runtime](https://kubernetes.io/docs/setup/production-environment/container-runtimes/) và xác nhận CRI được bật. Không dùng swap cho kubelet nếu chưa cấu hình hỗ trợ swap rõ ràng.

## 2. Tạo cluster

Lệnh đã dùng trên `cp1` để tạo cụm hiện tại:

```bash
sudo kubeadm init \
  --kubernetes-version v1.34.13 \
  --control-plane-endpoint k8s-api:6443 \
  --apiserver-advertise-address 192.168.51.100 \
  --apiserver-cert-extra-sans k8s-api,192.168.51.100 \
  --pod-network-cidr 10.244.0.0/16 \
  --upload-certs
mkdir -p "$HOME/.kube"
sudo cp /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"
```

Lưu **hai lệnh `kubeadm join` mà kubeadm in ra**: lệnh có `--control-plane --certificate-key` dùng trên `cp2`, `cp3`; lệnh còn lại dùng trên `wk1..wk3`. Certificate key và token hết hạn; nếu cần tạo lại: `sudo kubeadm init phase upload-certs --upload-certs` và `sudo kubeadm token create --print-join-command`. Đảm bảo `k8s-api:6443` truy cập được trước khi join node mới. Xem [quy trình kubeadm HA](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/).

### Kube-vip cho API HA

Trên mỗi control-plane, xác nhận interface chứa IP `192.168.51.x` là `ens33`, sau đó tạo cùng một Static Pod manifest. Lệnh dưới đây là cấu hình đang chạy; image được pin phiên bản, chỉ quản lý control-plane VIP và không quản lý Service `LoadBalancer`:

```bash
export KVVERSION=v1.2.4
export VIP=192.168.51.99
export INTERFACE=ens33
sudo ctr -n k8s.io images pull "ghcr.io/kube-vip/kube-vip:${KVVERSION}"
sudo ctr -n k8s.io run --rm --net-host \
  "ghcr.io/kube-vip/kube-vip:${KVVERSION}" vip-gen \
  /kube-vip manifest pod \
  --interface "$INTERFACE" \
  --address "$VIP" \
  --controlplane \
  --arp \
  --leaderElection \
  --image "ghcr.io/kube-vip/kube-vip:${KVVERSION}" \
  --k8sConfigPath /etc/kubernetes/admin.conf \
  | sudo tee /etc/kubernetes/manifests/kube-vip.yaml >/dev/null
```

Kubelet tự chạy manifest thành `kube-vip-cp1`, `kube-vip-cp2`, `kube-vip-cp3`. Kiểm tra leader, VIP và API:

```bash
kubectl -n kube-system get pods -o wide | grep kube-vip
kubectl -n kube-system get lease plndr-cp-lock \
  -o custom-columns='HOLDER:.spec.holderIdentity,RENEW:.spec.renewTime'
getent hosts k8s-api
ping -c 2 192.168.51.99
kubectl get --raw=/readyz
```

Phép thử thực tế đã tạm dừng kube-vip trên leader `cp3`: lease và VIP chuyển sang `cp1`, API tiếp tục trả `ok`, cả sáu node vẫn `Ready`; sau đó manifest trên `cp3` đã được khôi phục. Xem [hướng dẫn Static Pod của kube-vip](https://kube-vip.io/docs/installation/static/).

Trên `cp1`, cài Helm từ [hướng dẫn Helm](https://helm.sh/docs/intro/install/) (ví dụ Ubuntu có Snap) và Cilium 1.20.4. Kiểm tra kernel đáp ứng [yêu cầu Cilium](https://docs.cilium.io/en/stable/operations/system_requirements/):

```bash
sudo snap install helm --classic
helm upgrade --install cilium oci://quay.io/cilium/charts/cilium \
  --version 1.20.4 --namespace kube-system \
  --set ipam.mode=kubernetes --wait --timeout 15m
kubectl -n kube-system rollout status daemonset/cilium --timeout=15m
```

Sau khi sáu node `Ready`, bỏ taint trên ba control plane và gán zone. Thay tên nếu `kubectl get nodes` khác ví dụ:

```bash
kubectl taint nodes cp1 cp2 cp3 node-role.kubernetes.io/control-plane:NoSchedule-
kubectl label node cp1 wk1 topology.kubernetes.io/zone=rack-a --overwrite
kubectl label node cp2 wk2 topology.kubernetes.io/zone=rack-b --overwrite
kubectl label node cp3 wk3 topology.kubernetes.io/zone=rack-c --overwrite
kubectl get nodes -L topology.kubernetes.io/zone -o wide
```

Kiểm tra cụm hiện tại:

```bash
kubectl get nodes -L topology.kubernetes.io/zone
kubectl -n kube-system get ds cilium
kubectl -n kube-system get deploy cilium-operator coredns
kubectl get --raw=/readyz
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
```

Kết quả sau khi cài: 6 node `Ready`, Cilium `6/6`, Cilium Operator `2/2`, CoreDNS `2/2`, API trả `ok` và không có pod ở phase lỗi. Metrics-server ở mục tiếp theo cung cấp resource metrics cho HPA trong `app/hpa.yaml`; môi trường on-prem cần cấu hình chứng chỉ kubelet và DNS phù hợp, không tắt xác minh TLS chỉ để làm HPA chạy.

### Cài metrics-server và bật kubelet serving certificate

Metrics-server đọc CPU/RAM từ endpoint HTTPS `10250` của từng kubelet. Kubeadm mặc định tạo serving certificate tự ký, thường chỉ có DNS SAN; trong khi manifest metrics-server ưu tiên `InternalIP`. Khi đó pod không Ready và log có lỗi như sau:

```text
x509: cannot validate certificate for 192.168.51.103 because it doesn't contain any IP SANs
```

Không thêm `--kubelet-insecure-tls` trong production. Bật kubelet server TLS bootstrap để mỗi node xin certificate có DNS/IP SAN đúng và được Kubernetes CA ký. Với cluster mới, đặt `serverTLSBootstrap: true` trong `KubeletConfiguration` dùng cho `kubeadm init`. Với cluster hiện có, sửa ConfigMap chung:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
kubectl --context "$KUBE_CONTEXT" -n kube-system edit configmap kubelet-config
```

Trong tài liệu `KubeletConfiguration` tại `data.kubelet`, thêm trường top-level:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
serverTLSBootstrap: true
```

ConfigMap không tự sửa cấu hình kubelet đang chạy. Trên **từng node một**, sao lưu rồi thêm cùng trường vào `/var/lib/kubelet/config.yaml`; restart kubelet và chờ node trở lại `Ready` trước khi chuyển sang node tiếp theo:

```bash
sudo cp -an /var/lib/kubelet/config.yaml \
  /var/lib/kubelet/config.yaml.pre-server-tls-bootstrap
  
sudoedit /var/lib/kubelet/config.yaml
sudo systemctl restart kubelet
sudo systemctl is-active kubelet

# Chạy từ máy quản trị sau mỗi node.
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Ready node/<node-name> --timeout=120s
```

Kubelet tạo CSR với signer `kubernetes.io/kubelet-serving`. Kubernetes không tự approve loại CSR này. Kiểm tra requestor, usage và SAN trước khi duyệt; DNS/IP trong CSR phải thuộc đúng Node object:

```bash
kubectl --context "$KUBE_CONTEXT" get csr -o wide

CSR=<csr-name>
kubectl --context "$KUBE_CONTEXT" get csr "$CSR" \
  -o jsonpath='{.spec.signerName}{"\n"}{.spec.username}{"\n"}{.spec.usages}{"\n"}'
kubectl --context "$KUBE_CONTEXT" get csr "$CSR" -o jsonpath='{.spec.request}' \
  | base64 --decode | openssl req -noout -subject -text \
  | sed -n '/Subject:/p;/Subject Alternative Name/,+1p'
kubectl --context "$KUBE_CONTEXT" get node <node-name> \
  -o jsonpath='{range .status.addresses[*]}{.type}{"="}{.address}{"\n"}{end}'

# Chỉ approve sau khi đã đối chiếu requestor và toàn bộ SAN.
kubectl --context "$KUBE_CONTEXT" certificate approve "$CSR"
```

Lặp lại cho cả sáu node. CSR hợp lệ của cụm này có requestor `system:node:<node-name>`, usage `digital signature,server auth`, DNS SAN là hostname và IP SAN là `192.168.51.100..105`. Sau khi approve, trạng thái phải là `Approved,Issued`. Kubelet sẽ tạo CSR mới khi certificate gần hết hạn; cần theo dõi, kiểm tra và approve lại, hoặc triển khai approver có policy xác minh chặt requestor và SAN. Không tự động duyệt mọi CSR chỉ dựa trên signer hoặc Common Name.

Cài manifest metrics-server đã pin phiên bản:

```bash
METRICS_SERVER_VERSION=v0.9.1
kubectl --context "$KUBE_CONTEXT" apply -f \
  "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
kubectl --context "$KUBE_CONTEXT" -n kube-system \
  rollout status deployment/metrics-server --timeout=5m
```

Xác nhận API aggregation, metric của cả sáu node và workload:

```bash
kubectl --context "$KUBE_CONTEXT" wait --for=condition=Available \
  apiservice/v1beta1.metrics.k8s.io --timeout=120s
kubectl --context "$KUBE_CONTEXT" get apiservice v1beta1.metrics.k8s.io
kubectl --context "$KUBE_CONTEXT" top nodes
kubectl --context "$KUBE_CONTEXT" top pods -A
kubectl --context "$KUBE_CONTEXT" -n kube-system logs deployment/metrics-server --tail=100
```

Nếu `APIService` báo `MissingEndpoints`, kiểm tra readiness và log metrics-server trước; đây thường là hậu quả của việc chưa scrape được kubelet. Trường `APIService.spec.insecureSkipTLSVerify` trong manifest mặc định chỉ áp dụng cho kết nối kube-apiserver tới metrics-server, không thay thế và không liên quan tới `--kubelet-insecure-tls` trên kết nối metrics-server tới kubelet. Sau khi Metrics API hoạt động mới apply [`app/hpa.yaml`](app/hpa.yaml).

### Bật lại cluster sau khi shutdown VMware

Node đã join cluster **không cần chạy lại `kubeadm join` sau reboot**. Kubelet giữ kubeconfig và certificate trong `/etc/kubernetes`; khi VM, `containerd` và `kubelet` khởi động, node sẽ tự kết nối lại. [`kubeadm join`](https://kubernetes.io/docs/reference/setup-tools/kubeadm/kubeadm-join/) dùng để khởi tạo một node mới; chạy lại trên node cũ có thể thất bại hoặc tạo trạng thái khó khôi phục.

Trong VMware Workstation, bật `cp1`, `cp2`, `cp3` trước; sau khi ba control plane khởi động, bật `wk1`, `wk2`, `wk3`. Giữ nguyên IP, hostname, MAC/network adapter và các data disk. Không rollback snapshot riêng lẻ của một control plane vì trạng thái etcd có thể lệch với hai thành viên còn lại.

Từ máy local đã có kubeconfig, chạy script ở root repo:

```bash
export KUBECONFIG="$HOME/.kube/k8s-onprem.conf"
bash resume-cluster.sh
```

Script chờ API tại VIP, chờ đúng sáu node `Ready`, kiểm tra zone, Cilium, CoreDNS, kube-vip và pod lỗi. Script không bật VM và không chứa mật khẩu. Nếu VM đã bật nhưng `containerd` hoặc `kubelet` không tự chạy, dùng tùy chọn sau; SSH/sudo có thể hỏi mật khẩu của user `ky`:

```bash
bash resume-cluster.sh --repair-services
```

Trước khi dùng workload stateful, xác nhận các data disk đã tự mount lại từ `/etc/fstab`; đặc biệt không để kubelet ghi dữ liệu mới vào thư mục rỗng trên root disk khi mount bị thiếu:

```bash
for path in elasticsearch kafka redis-data redis-conf; do
  findmnt "/srv/k8s-local/$path"
done
```

Lệnh `findmnt` phải chạy trên từng node có mount tương ứng, không phải máy local. Nếu script báo thiếu `/etc/kubernetes/kubelet.conf` hoặc node không còn trong `kubectl get nodes`, dừng lại để chẩn đoán node đó. Chỉ tạo lệnh `kubeadm join` mới khi node đã thực sự bị reset/thay thế; control-plane cần quy trình riêng và certificate key mới, không dùng cùng lệnh với worker.

### Kết nối bằng kubectl từ máy local

Máy local phải truy cập được mạng `192.168.51.0/24`. Cài `kubectl` cùng minor version với cluster; ví dụ Linux `amd64`:

```bash
curl -LO https://dl.k8s.io/release/v1.34.13/bin/linux/amd64/kubectl
curl -LO https://dl.k8s.io/release/v1.34.13/bin/linux/amd64/kubectl.sha256
echo "$(cat kubectl.sha256) kubectl" | sha256sum --check
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl kubectl.sha256
kubectl version --client
```

Cài thêm `jq` để xử lý JSON và Helm để triển khai chart từ máy local:

```bash
sudo apt-get update
sudo apt-get install -y jq
sudo snap install helm --classic
export PATH="/snap/bin:$PATH"
rehash
jq --version
helm version
```

Trên `zsh`, nếu Snap báo đã cài Helm nhưng shell trả về `command not found: helm`, lưu `/snap/bin` vào `PATH` rồi mở lại shell:

```bash
grep -qxF 'export PATH="/snap/bin:$PATH"' "$HOME/.zshrc" || \
  echo 'export PATH="/snap/bin:$PATH"' >> "$HOME/.zshrc"
source "$HOME/.zshrc"
rehash
command -v helm
helm version
```

Kết quả `command -v helm` dự kiến là `/snap/bin/helm`. Nếu Helm đã được cài bằng Snap, lệnh cài đặt sẽ báo package đã tồn tại; dùng `sudo snap refresh helm` để cập nhật. Helm không bắt buộc để `kubectl` kết nối cluster, nhưng cần cho các bước triển khai chart như Cilium hoặc operator.

Trên máy local, thêm đúng một mapping sau vào `/etc/hosts` (hoặc dùng DNS nội bộ tương đương):

```text
192.168.51.99 k8s-api
```

Không đổi server trong kubeconfig thành IP `192.168.51.99`, vì certificate API được cấp cho hostname `k8s-api`. Kiểm tra phân giải và kết nối mạng:

```bash
getent hosts k8s-api
ping -c 2 k8s-api
```

Sao chép kubeconfig quản trị từ `cp1` vào một file riêng để không ghi đè cluster khác đã có trên máy local:

```bash
mkdir -p "$HOME/.kube"
scp -F /dev/null \
  ky@192.168.51.100:/home/ky/.kube/config \
  "$HOME/.kube/k8s-onprem.conf"
chmod 600 "$HOME/.kube/k8s-onprem.conf"
export KUBECONFIG="$HOME/.kube/k8s-onprem.conf"
```

`scp` sẽ hỏi mật khẩu SSH của user `ky`; không ghi mật khẩu vào README hoặc script. Biến `KUBECONFIG` ở trên chỉ áp dụng cho shell hiện tại. Có thể truyền `--kubeconfig "$HOME/.kube/k8s-onprem.conf"` cho từng lệnh nếu không muốn export biến môi trường.

Xác minh truy cập qua VIP:

```bash
kubectl config current-context
kubectl cluster-info
kubectl get --raw=/readyz
kubectl get nodes -L topology.kubernetes.io/zone
kubectl get pods -A
```

Kết quả mong đợi: API trả `ok` và sáu node đều `Ready`. File kubeconfig này có quyền quản trị cluster; không commit vào Git, không chia sẻ và luôn giữ quyền file `600`. Nên tạo user/ServiceAccount với RBAC giới hạn cho công việc hằng ngày thay vì dùng kubeconfig quản trị lâu dài.

## 3. Chuẩn bị local PV

Local PV là **PV tĩnh**, không có provisioner động. Trên mỗi node, gắn filesystem/partition dữ liệu riêng vào các đường dẫn dưới đây **trước** khi áp PV; bảo đảm chúng được mount lại sau reboot. Dùng `lsblk -f` để chọn đúng thiết bị, tạo ext4/XFS, gắn qua UUID trong `/etc/fstab` rồi `findmnt` xác nhận. Không format ổ chứa dữ liệu cũ. Mỗi node cần `elasticsearch` 50 GiB, `kafka` 50 GiB, `redis-data` 20 GiB, `redis-conf` 1 GiB. `cp1` cần thêm `redisinsight` 5 GiB và `redis-backup` 50 GiB. Hai đường dẫn `kibana` và `app` chỉ cần khi dùng PVC kiểm tra tùy chọn. Tạo quyền ghi phù hợp với UID của container (Elastic/Redis/RedisInsight thường 1000, Kafka theo image Strimzi, backup 999), kiểm tra Pod sau khi cài:

```bash
# Ví dụ cho một phân vùng trống đã được chọn để chứa dữ liệu Elasticsearch.
DISK=/dev/disk/by-id/REPLACE_WITH_EMPTY_PARTITION
sudo mkfs.ext4 "$DISK"
sudo install -d /srv/k8s-local/elasticsearch
sudo blkid "$DISK"   # lấy UUID thật
# Thêm vào /etc/fstab: UUID=<uuid-that> /srv/k8s-local/elasticsearch ext4 defaults 0 2
sudo mount /srv/k8s-local/elasticsearch
sudo chown 1000:1000 /srv/k8s-local/elasticsearch
findmnt /srv/k8s-local/elasticsearch
findmnt /srv/k8s-local/kafka
findmnt /srv/k8s-local/redis-data
findmnt /srv/k8s-local/redis-conf
# Trên cp1:
findmnt /srv/k8s-local/redisinsight
findmnt /srv/k8s-local/redis-backup
# Tùy chọn:
findmnt /srv/k8s-local/kibana
findmnt /srv/k8s-local/app
```

Các file PV dùng tên node `cp1`, `cp2`, `cp3`, `wk1`, `wk2`, `wk3`. Nếu `kubectl get nodes` trả tên khác, sửa `values` trong từng file `pv.yaml` trước khi apply. Từ gốc repo:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
for component in elasticsearch kafka-cluster redis-cluster redisinsight kibana app; do
  kubectl --context "$KUBE_CONTEXT" apply -f "$component/storage-class.yaml"
  kubectl --context "$KUBE_CONTEXT" apply -f "$component/pv.yaml"
done
kubectl --context "$KUBE_CONTEXT" get pv -o wide
```

Mỗi dịch vụ sở hữu StorageClass, PV và PVC trong thư mục của nó. `nodeAffinity` khóa PV vào node tương ứng; `WaitForFirstConsumer` cho scheduler chọn PV cùng node với Pod. PV `Available` trước khi có PVC là bình thường. ECK, Strimzi và Redis Operator tự tạo PVC dữ liệu từ manifest workload; không apply các PVC kiểm tra của chúng trong lúc cài. Kibana và Node API hiện stateless nên `pvc.yaml` của hai thư mục cũng chỉ dùng kiểm tra. Sau khi bind, kiểm tra PVC và Pod cùng node. Nếu node/ổ đĩa hỏng, PVC/PV không tự chuyển sang node khác; phục hồi từ backup trên node/ổ mới, cập nhật PV và thử restore. `Retain` giữ dữ liệu sau khi xóa PVC; phải xử lý `claimRef` và dữ liệu cũ có chủ đích trước khi tái dùng PV. Xem [tài liệu local volumes](https://kubernetes.io/docs/concepts/storage/volumes/#local) và [StorageClass binding](https://kubernetes.io/docs/concepts/storage/storage-classes/#volume-binding-mode).

## 4. Cài workload

Thực hiện theo thứ tự sau, luôn dùng đúng `KUBE_CONTEXT`:

1. [Elasticsearch/ECK](elasticsearch/ELASTICSEARCH.md): ECK tự tạo PVC từ `elasticsearch.yaml`.
2. [Redis Cluster](redis-cluster/README.md): 3 leader + 3 follower, dữ liệu và `nodes.conf` có PV riêng.
3. [Kafka/Strimzi](kafka-cluster/README.md): 6 broker/controller và Kafka Connect. PostgreSQL cho CDC phải được triển khai riêng trên LAN.
4. [Kibana](kibana/KIBANA.md), [RedisInsight](redisinsight/README.md), [Node API](app/README.md).

Các image tùy chỉnh (`redis-cluster`, backup Redis, Kafka Connect, Node API) cần được build/push tới registry mà cả sáu node kéo được và sửa `image` trong manifest. Không áp dụng file `*.example.yaml` chứa placeholder. `kibana` và `redisinsight` dùng `kubectl port-forward` trên máy quản trị; nếu cần truy cập LAN, thêm ingress controller, DNS và TLS theo môi trường. Không có ALB/ACM/Route 53 trong cấu hình này.

## 5. Kiểm tra và sao lưu

```bash
kubectl --context "$KUBE_CONTEXT" get nodes -L topology.kubernetes.io/zone
kubectl --context "$KUBE_CONTEXT" get pv
kubectl --context "$KUBE_CONTEXT" get pvc -A
kubectl --context "$KUBE_CONTEXT" get pods -A -o wide
KUBE_CONTEXT="$KUBE_CONTEXT" bash elasticsearch/check.sh
KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
KUBE_CONTEXT="$KUBE_CONTEXT" bash kafka-cluster/check.sh
```

Redis CronJob ghi RDB vào local PV trên `cp1` và cần **chép bản backup ra hệ thống lưu trữ ngoài cluster** sau mỗi lần chạy; một local PV không phải bản sao lưu khi cả node hoặc rack hỏng. Elasticsearch cần snapshot repository dùng chung ngoài các PVC dữ liệu (ví dụ NFS/S3 compatible được cấu hình riêng). Kafka cần chính sách backup/khôi phục topic và metadata ngoài cluster. Sao lưu etcd theo [tài liệu Kubernetes](https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/#backing-up-an-etcd-cluster) và giữ bản sao ngoài ba control plane. Kiểm tra restore định kỳ trước khi dùng dữ liệu production. Đây là **chuyển đổi manifest và runbook**, không tự chuyển dữ liệu AWS cũ sang ổ local; cần export/restore dữ liệu riêng trước khi đổi traffic.
