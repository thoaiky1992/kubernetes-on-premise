#!/usr/bin/env bash
# Kiểm tra primary shard và replica của Elasticsearch: mỗi bản sao nằm ở node nào, thuộc AZ nào.
# Truy vấn bằng curl chạy bên trong một Pod (xác minh TLS bằng CA của ECK); mật khẩu đi qua stdin, không in ra.
# Tên node Elasticsearch do ECK đặt bằng tên Pod, nên AZ lấy từ label zone của Node chứa Pod đó.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
NAMESPACE="${NAMESPACE:-elasticsearch}"
ES_CLUSTER="${ES_CLUSTER:-search}"
ES_POD="${ES_POD:-${ES_CLUSTER}-es-default-0}"
ES_AUTH_SECRET="${ES_AUTH_SECRET:-elastic-auth}"
ES_URL="https://${ES_CLUSTER}-es-http.${NAMESPACE}.svc:9200"
CA_FILE=/usr/share/elasticsearch/config/http-certs/ca.crt

command -v kubectl >/dev/null || { echo 'Thiếu kubectl' >&2; exit 1; }
command -v jq >/dev/null || { echo 'Thiếu jq' >&2; exit 1; }

kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")
failed=0
warned=0

# Cluster dùng auth.fileRealm (elasticsearch.yaml) nên thông tin đăng nhập nằm trong Secret elastic-auth, không phải search-es-elastic-user.
ES_USER="$("${kubectl_cmd[@]}" get secret "$ES_AUTH_SECRET" -o jsonpath='{.data.username}' | base64 --decode)"
ES_PASSWORD="$("${kubectl_cmd[@]}" get secret "$ES_AUTH_SECRET" -o jsonpath='{.data.password}' | base64 --decode)"

# Gọi API Elasticsearch qua Pod. Thông tin đăng nhập được ghi vào stdin của curl (-K -), không nằm trên dòng lệnh.
es_get() { # es_get <đường dẫn API>
  printf 'user = "%s:%s"\n' "$ES_USER" "$ES_PASSWORD" | "${kubectl_cmd[@]}" exec -i "$ES_POD" -c elasticsearch -- \
    curl -sS --cacert "$CA_FILE" -K - "$ES_URL/$1"
}

echo "Context: $KUBE_CONTEXT | namespace: $NAMESPACE | cluster: $ES_CLUSTER | pod: $ES_POD"

health_json="$(es_get '_cluster/health')"
status="$(jq -r '.status' <<<"$health_json")"
echo "Trạng thái cluster: $status (unassigned_shards=$(jq -r '.unassigned_shards' <<<"$health_json"))"
if [[ "$status" == red ]]; then
  echo 'FAIL: cluster đang red; có primary shard chưa được gán.' >&2
  failed=1
fi

# Ánh xạ Node -> AZ: lấy node chứa từng Pod Elasticsearch, rồi đọc label zone của Node đó.
declare -A node_zone=() pod_zone=()
while IFS=$'\t' read -r n z; do
  node_zone["$n"]="$z"
done < <("${kubectl_cmd[@]}" get nodes -o json | jq -r '.items[] | [.metadata.name, (.metadata.labels["topology.kubernetes.io/zone"] // "unknown")] | @tsv')

while IFS=$'\t' read -r pod node; do
  # Pod Pending (ví dụ khi mất AZ) chưa có node: không tra cứu khóa rỗng trong mảng kết hợp.
  if [[ -z "$node" ]]; then
    pod_zone["$pod"]=unknown
  else
    pod_zone["$pod"]="${node_zone[$node]:-unknown}"
  fi
done < <("${kubectl_cmd[@]}" get pods -l "elasticsearch.k8s.elastic.co/cluster-name=$ES_CLUSTER" -o json \
  | jq -r '.items[] | [.metadata.name, (.spec.nodeName // "")] | @tsv')

if (( ${#pod_zone[@]} == 0 )); then
  echo "FAIL: không tìm thấy Pod nào của cluster $ES_CLUSTER trong namespace $NAMESPACE." >&2
  exit 1
fi

shards_json="$(es_get '_cat/shards?format=json&h=index,shard,prirep,state,node')"

declare -A primary_zone=() replica_zones=() primary_count=() replica_count=() shard_state=()
echo
printf '%-28s %-6s %-9s %-12s %-42s %s\n' INDEX SHARD TYPE STATE NODE AZ
while IFS=$'\t' read -r index shard prirep state node; do
  if [[ "$prirep" == p ]]; then type=primary; else type=replica; fi
  if [[ -z "$node" ]]; then
    node=UNASSIGNED
    zone='-'
  else
    zone="${pod_zone[$node]:-unknown}"
  fi
  printf '%-28s %-6s %-9s %-12s %-42s %s\n' "$index" "$shard" "$type" "$state" "$node" "$zone"

  key="$index/$shard"
  if [[ "$state" != STARTED ]]; then
    echo "FAIL: $key ($type) ở trạng thái $state." >&2
    failed=1
  fi
  if [[ "$type" == primary ]]; then
    primary_zone["$key"]="$zone"
    primary_count["$zone"]=$(( ${primary_count[$zone]:-0} + 1 ))
  else
    replica_zones["$key"]="${replica_zones[$key]:-} $zone"
    replica_count["$zone"]=$(( ${replica_count[$zone]:-0} + 1 ))
  fi
done < <(jq -r '.[] | [.index, .shard, .prirep, .state, (.node // "")] | @tsv' <<<"$shards_json")

# Mỗi replica phải khác AZ với primary của cùng shard, nếu không một AZ mất sẽ mất cả hai bản sao.
echo
for key in "${!primary_zone[@]}"; do
  for rz in ${replica_zones[$key]:-}; do
    if [[ "$rz" == "${primary_zone[$key]}" ]]; then
      echo "WARN: $key có replica cùng AZ ${rz} với primary." >&2
      warned=1
    fi
  done
done

echo "Số primary theo AZ:"
for z in "${!primary_count[@]}"; do echo "  $z: ${primary_count[$z]}"; done
echo "Số replica theo AZ:"
for z in "${!replica_count[@]}"; do echo "  $z: ${replica_count[$z]}"; done

echo
if (( failed )); then
  echo 'Kiểm tra shard thất bại. Xem các dòng FAIL phía trên.' >&2
  exit 1
fi
if (( warned )); then
  echo 'Các shard có bản sao, nhưng có replica cùng AZ với primary (xem WARN).'
  exit 0
fi
echo 'Shard hoạt động; mỗi replica nằm ở AZ khác primary.'
