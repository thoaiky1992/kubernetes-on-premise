#!/usr/bin/env bash
# Kiểm tra RedisCluster: trạng thái cluster, 3 master có đủ replica, label role và phân bố AZ.
# redis-cli chạy bên trong Pod leader và dùng REDISCLI_AUTH có sẵn trong Pod,
# nên mật khẩu không được đưa ra máy này và không được in ra.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
NAMESPACE="${NAMESPACE:-redis-cluster}"
CLI_POD="${CLI_POD:-redis-cluster-leader-0}"
SEED_HOST="redis-cluster-leader.${NAMESPACE}.svc.cluster.local"
REDIS_PORT=6379
EXPECTED_MASTERS=3
EXPECTED_NODES=6

command -v kubectl >/dev/null || { echo 'Thiếu kubectl' >&2; exit 1; }

kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")

# Chạy redis-cli trong Pod leader; TLS xác minh bằng CA đã mount ở /tls và SNI khớp SAN.
pod_cli() {
  "${kubectl_cmd[@]}" exec "$CLI_POD" -- redis-cli --tls --cacert /tls/ca.crt \
    --sni "$SEED_HOST" -h "$SEED_HOST" -p "$REDIS_PORT" "$@"
}

failed=0
warned=0
collision=0
echo "Context: $KUBE_CONTEXT | namespace: $NAMESPACE | pod: $CLI_POD"

# 1. Trạng thái cluster: đủ node, đủ slot, state ok.
info="$(pod_cli --raw CLUSTER INFO | tr -d '\r')"
state="$(awk -F: '/^cluster_state:/{print $2}' <<<"$info")"
known="$(awk -F: '/^cluster_known_nodes:/{print $2}' <<<"$info")"
slots_ok="$(awk -F: '/^cluster_slots_ok:/{print $2}' <<<"$info")"
if [[ "$state" == "ok" && "$known" == "$EXPECTED_NODES" && "$slots_ok" == "16384" ]]; then
  echo "OK: cluster_state=ok, known_nodes=$known, slots_ok=$slots_ok"
else
  echo "FAIL: cluster_state=$state known_nodes=$known slots_ok=$slots_ok (cần ok/$EXPECTED_NODES/16384)" >&2
  failed=1
fi

# 2. Label role phải khớp với affinity trong redis-cluster.yaml; nếu không khớp thì
#    podAntiAffinity không có tác dụng và các leader có thể dồn vào cùng một AZ.
for role in leader follower; do
  count="$("${kubectl_cmd[@]}" get pods -l "role=$role" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" == "3" ]]; then
    echo "OK: pod có label role=$role: $count"
  else
    echo "FAIL: pod có label role=$role: $count (cần 3). Kiểm tra bằng kubectl get pods --show-labels." >&2
    failed=1
  fi
done

# 3. Topology: CLUSTER NODES cho biết ai là master, ai là replica của ai.
nodes="$(pod_cli --raw CLUSTER NODES | tr -d '\r')"

declare -A zone_of=() pod_of=() role_of=() master_of=()
masters=()
while read -r node_id addr flags master_id _rest; do
  if [[ "$flags" == *fail* ]]; then
    echo "FAIL: node $node_id đang có cờ fail." >&2
    failed=1
    continue
  fi
  if [[ "$addr" != *,* ]]; then
    echo "FAIL: node $node_id chưa announce hostname; TLS và cluster-preferred-endpoint-type hostname sẽ lỗi." >&2
    failed=1
    continue
  fi
  host="${addr#*,}"
  pod="${host%%.*}"
  node_name="$("${kubectl_cmd[@]}" get pod "$pod" -o jsonpath='{.spec.nodeName}' 2>/dev/null || true)"
  zone="$("${kubectl_cmd[@]}" get node "$node_name" -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}' 2>/dev/null || true)"
  pod_of["$node_id"]="$pod"
  zone_of["$node_id"]="${zone:-unknown}"
  if [[ "$flags" == *master* ]]; then
    role_of["$node_id"]="master"
    masters+=("$node_id")
  else
    role_of["$node_id"]="replica"
    master_of["$node_id"]="$master_id"
  fi
done < <(awk '{print $1, $2, $3, $4}' <<<"$nodes")

if (( ${#masters[@]} != EXPECTED_MASTERS )); then
  echo "FAIL: số master=${#masters[@]}, cần $EXPECTED_MASTERS." >&2
  failed=1
fi

echo
printf '%-10s %-40s %-16s %s\n' ROLE POD ZONE REPLICA_OF
declare -A master_zone_seen=()
for id in "${masters[@]}"; do
  printf '%-10s %-40s %-16s %s\n' master "${pod_of[$id]:-?}" "${zone_of[$id]:-?}" -
  if [[ -n "${master_zone_seen[${zone_of[$id]:-?}]:-}" ]]; then
    echo "FAIL: hai master cùng AZ ${zone_of[$id]:-?}; một AZ mất sẽ mất hai shard." >&2
    failed=1
    collision=1
  fi
  master_zone_seen["${zone_of[$id]:-?}"]=1

  replicas=0
  for rid in "${!master_of[@]}"; do
    [[ "${master_of[$rid]}" == "$id" ]] || continue
    replicas=$((replicas + 1))
    printf '%-10s %-40s %-16s %s\n' replica "${pod_of[$rid]:-?}" "${zone_of[$rid]:-?}" "${pod_of[$id]:-?}"
    if [[ "${zone_of[$rid]:-?}" == "${zone_of[$id]:-?}" ]]; then
      echo "WARN: ${pod_of[$rid]:-?} và master ${pod_of[$id]:-?} cùng AZ ${zone_of[$id]:-?}; AZ này mất thì shard đó mất cả master lẫn replica." >&2
      warned=1
    fi
  done
  if (( replicas != 1 )); then
    echo "FAIL: master ${pod_of[$id]:-?} có $replicas replica, cần đúng 1." >&2
    failed=1
  fi
done

# 4. Khi hai master trở lên cùng AZ, in các lệnh CLUSTER FAILOVER để mỗi AZ còn tối đa một master.
#    Mỗi bước chọn replica ở AZ chưa có master, đang replicate master ở AZ bị trùng. Chỉ in lệnh, không tự chạy.
plan_zone_collisions() {
  local -A sim_master=() cnt=() seen=()
  local -a zones=() steps=()
  local id z r m D F i s rp role h

  for id in "${!zone_of[@]}"; do
    if [[ "${zone_of[$id]}" == unknown ]]; then
      echo "WARN: chưa xác định được AZ của ${pod_of[$id]:-$id}; không lập kế hoạch failover." >&2
      return 1
    fi
    z="${zone_of[$id]}"
    if [[ -z "${seen[$z]:-}" ]]; then
      seen[$z]=1
      zones+=("$z")
    fi
    sim_master[$id]="${master_of[$id]:-}"
  done

  for ((i = 1; i <= 10; i++)); do
    cnt=()
    for z in "${zones[@]}"; do cnt[$z]=0; done
    for id in "${!zone_of[@]}"; do
      if [[ -z "${sim_master[$id]}" ]]; then
        cnt[${zone_of[$id]}]=$(( cnt[${zone_of[$id]}] + 1 ))
      fi
    done

    D=""; F=""
    for z in "${zones[@]}"; do
      if (( cnt[$z] >= 2 )); then D="$z"; fi
      if (( cnt[$z] == 0 )) && [[ -z "$F" ]]; then F="$z"; fi
    done
    [[ -n "$D" ]] || break
    if [[ -z "$F" ]]; then
      echo "Không có AZ trống để chuyển master sang; cần thêm node ở AZ còn thiếu hoặc xử lý thủ công." >&2
      return 1
    fi

    r=""; m=""
    for id in "${!zone_of[@]}"; do
      [[ -n "${sim_master[$id]}" ]] || continue
      if [[ "${zone_of[$id]}" == "$F" && "${zone_of[${sim_master[$id]}]}" == "$D" ]]; then
        r="$id"; m="${sim_master[$id]}"
        break
      fi
    done
    if [[ -z "$r" ]]; then
      echo "Không tìm được replica ở AZ $F đang replicate master ở AZ $D; xử lý thủ công theo mục Phân bố AZ trong README." >&2
      return 1
    fi

    steps+=("$r|$m|$F|$D")
    sim_master[$r]=""
    sim_master[$m]="$r"
  done

  (( ${#steps[@]} > 0 )) || return 0
  echo
  echo "Kế hoạch đưa mỗi master về một AZ riêng. Chạy tuần tự từng lệnh, rồi chạy lại script sau mỗi bước:"
  i=0
  for s in "${steps[@]}"; do
    IFS='|' read -r r m F D <<<"$s"
    i=$((i + 1))
    rp="${pod_of[$r]}"; role="${rp%-*}"; h="$rp.$role-headless.$NAMESPACE.svc.cluster.local"
    echo "# Bước $i: $rp (AZ $F) lên master; ${pod_of[$m]} (AZ $D) xuống replica"
    echo -e "\nkubectl --context \"\$KUBE_CONTEXT\" -n $NAMESPACE exec $rp -- redis-cli --tls --cacert /tls/ca.crt --sni $h -h $h -p 6379 CLUSTER FAILOVER"
    echo -e "\nsleep 10"
  done
  echo
  echo "KUBE_CONTEXT=\"\$KUBE_CONTEXT\" bash redis-cluster/check-cluster.sh"
}

if (( collision )); then
  plan_zone_collisions || true
fi

echo
if (( failed )); then
  echo 'Kiểm tra RedisCluster thất bại. Xem các dòng FAIL phía trên.' >&2
  exit 1
fi
if (( warned )); then
  echo 'RedisCluster hoạt động, nhưng có cặp master/replica cùng AZ (xem WARN). Xem mục "Phân bố AZ" trong README.'
  exit 0
fi
echo 'RedisCluster hoạt động: 3 master, mỗi master có 1 replica ở AZ khác.'
