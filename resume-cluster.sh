#!/usr/bin/env bash
# Kiểm tra/phục hồi cluster sau khi bật lại 6 VM. Reboot không cần kubeadm join.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-}"
SSH_USER="${SSH_USER:-ky}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
repair_services=0

node_names=(cp1 cp2 cp3 wk1 wk2 wk3)
node_ips=(
  192.168.51.100
  192.168.51.101
  192.168.51.102
  192.168.51.103
  192.168.51.104
  192.168.51.105
)
expected_zones=(rack-a rack-b rack-c rack-a rack-b rack-c)

usage() {
  cat <<'EOF'
Usage:
  bash resume-cluster.sh [--repair-services]

Options:
  --repair-services  Qua SSH, bật containerd và kubelet nếu chúng chưa chạy.
                     Có thể hỏi mật khẩu SSH/sudo trên từng node.
  -h, --help         Hiện trợ giúp.

Environment:
  KUBE_CONTEXT  Context kubectl; mặc định dùng context hiện tại.
  SSH_USER      User SSH; mặc định ky.
  WAIT_TIMEOUT  Số giây chờ API và sáu node Ready; mặc định 600.

Script không chạy kubeadm join. Node đã join sẽ tự kết nối lại bằng
/etc/kubernetes/kubelet.conf khi kubelet khởi động.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --repair-services) repair_services=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Tham số không hợp lệ: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v kubectl >/dev/null || { echo 'Thiếu kubectl.' >&2; exit 1; }
if (( repair_services == 1 )); then
  command -v ssh >/dev/null || { echo 'Thiếu ssh.' >&2; exit 1; }
fi
if [[ ! "$WAIT_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
  echo 'WAIT_TIMEOUT phải là số nguyên dương.' >&2
  exit 2
fi

if [[ -z "$KUBE_CONTEXT" ]]; then
  KUBE_CONTEXT="$(kubectl config current-context)"
fi
kubectl config get-contexts "$KUBE_CONTEXT" >/dev/null
kubectl_cmd=(kubectl --context "$KUBE_CONTEXT")

check_api_name_resolution() {
  local api_server api_host
  api_server="$("${kubectl_cmd[@]}" config view --minify \
    -o jsonpath='{.clusters[0].cluster.server}')"
  api_host="${api_server#*://}"
  api_host="${api_host%%:*}"
  if [[ -z "$api_host" ]]; then
    echo "Không đọc được API server từ context $KUBE_CONTEXT." >&2
    return 1
  fi
  if ! getent hosts "$api_host" >/dev/null; then
    cat >&2 <<EOF
Không phân giải được API hostname '$api_host' (server: $api_server).
Thêm vào /etc/hosts của máy local rồi chạy lại:
  192.168.51.99 $api_host
EOF
    return 1
  fi
}

repair_node_services() {
  local i name ip rc
  echo 'Kiểm tra containerd/kubelet trên sáu node...'
  for i in "${!node_names[@]}"; do
    name="${node_names[$i]}"
    ip="${node_ips[$i]}"
    echo
    echo "[$name] $SSH_USER@$ip"
    rc=0
    ssh -F /dev/null -tt \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=8 \
      "$SSH_USER@$ip" \
      'if [ ! -s /etc/kubernetes/kubelet.conf ]; then
         echo "ERROR: thiếu /etc/kubernetes/kubelet.conf; không tự chạy kubeadm join." >&2
         exit 42
       fi
       if ! systemctl is-active --quiet containerd ||
          ! systemctl is-active --quiet kubelet; then
         sudo systemctl enable --now containerd kubelet
       fi
       printf "containerd=%s kubelet=%s\n" \
         "$(systemctl is-active containerd)" "$(systemctl is-active kubelet)"' || rc=$?
    if (( rc == 42 )); then
      echo "Node $name đã mất cấu hình kubelet; dừng để tránh join nhầm cluster." >&2
      exit 1
    elif (( rc != 0 )); then
      echo "Không thể kiểm tra hoặc bật dịch vụ trên $name (SSH exit $rc)." >&2
      exit 1
    fi
  done
}

wait_for_api() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  echo "Chờ Kubernetes API qua VIP (tối đa ${WAIT_TIMEOUT}s)..."
  until "${kubectl_cmd[@]}" get --raw=/readyz >/dev/null 2>&1; do
    if (( SECONDS >= deadline )); then
      cat >&2 <<EOF
Timeout: API chưa sẵn sàng.
Xác nhận cp1..cp3 đã bật, k8s-api phân giải tới 192.168.51.99 và chạy:
  bash resume-cluster.sh --repair-services
EOF
      return 1
    fi
    sleep 5
  done
  echo 'OK: API readyz.'
}

node_ready() {
  local node="$1" status
  status="$("${kubectl_cmd[@]}" get node "$node" \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' \
    2>/dev/null || true)"
  [[ "$status" == True ]]
}

wait_for_nodes() {
  local deadline=$((SECONDS + WAIT_TIMEOUT))
  local node all_ready
  echo 'Chờ cp1..cp3 và wk1..wk3 ở trạng thái Ready...'
  while :; do
    all_ready=1
    for node in "${node_names[@]}"; do
      if ! node_ready "$node"; then
        all_ready=0
      fi
    done
    if (( all_ready == 1 )); then
      echo 'OK: cả sáu node Ready.'
      return 0
    fi
    if (( SECONDS >= deadline )); then
      echo 'Timeout: chưa đủ sáu node Ready.' >&2
      "${kubectl_cmd[@]}" get nodes -L topology.kubernetes.io/zone -o wide || true
      echo 'Không chạy kubeadm join lại; kiểm tra journalctl -u kubelet trên node NotReady.' >&2
      return 1
    fi
    sleep 5
  done
}

check_zones() {
  local i node actual failed=0
  for i in "${!node_names[@]}"; do
    node="${node_names[$i]}"
    actual="$("${kubectl_cmd[@]}" get node "$node" \
      -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
    if [[ "$actual" != "${expected_zones[$i]}" ]]; then
      echo "Sai zone: $node có '$actual', cần '${expected_zones[$i]}'." >&2
      failed=1
    fi
  done
  (( failed == 0 )) || return 1
  echo 'OK: nhãn zone đúng.'
}

check_system_workloads() {
  echo 'Chờ Cilium và DNS...'
  "${kubectl_cmd[@]}" -n kube-system rollout status daemonset/cilium --timeout=5m
  "${kubectl_cmd[@]}" -n kube-system rollout status deployment/cilium-operator --timeout=5m
  "${kubectl_cmd[@]}" -n kube-system rollout status deployment/coredns --timeout=5m
  echo
  "${kubectl_cmd[@]}" -n kube-system get pods -o wide | awk 'NR == 1 || /kube-vip/'
}

echo "Context: $KUBE_CONTEXT"
echo 'Lưu ý: VM phải được bật trước; script không điều khiển VMware Workstation.'
check_api_name_resolution
if (( repair_services == 1 )); then
  repair_node_services
fi
wait_for_api
wait_for_nodes
check_zones
check_system_workloads

echo
"${kubectl_cmd[@]}" get nodes -L topology.kubernetes.io/zone -o wide
echo
non_running="$("${kubectl_cmd[@]}" get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded \
  --no-headers 2>/dev/null || true)"
if [[ -n "$non_running" ]]; then
  echo 'WARN: còn pod chưa Running/Succeeded:' >&2
  printf '%s\n' "$non_running" >&2
  exit 1
fi

echo 'OK: cluster đã hoạt động lại; không cần kubeadm join.'
