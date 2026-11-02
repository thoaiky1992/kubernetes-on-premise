#!/usr/bin/env bash
# Bảo đảm Redis Cluster 3 master + 3 replica có đúng 1 master và 1 replica mỗi
# zone, đồng thời replica không nằm cùng zone với master mà nó replicate.
# Mặc định chỉ in kế hoạch; --apply có thể thực hiện CLUSTER REPLICATE
# và CLUSTER FAILOVER có kiểm soát để sửa phân bố role giữa các zone.
set -euo pipefail

KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
NAMESPACE="${NAMESPACE:-redis-cluster}"
CLI_POD="${CLI_POD:-redis-cluster-leader-0}"
SEED_HOST="redis-cluster-leader.${NAMESPACE}.svc.cluster.local"
REDIS_PORT=6379
REPLICATION_TIMEOUT="${REPLICATION_TIMEOUT:-300}"
apply=0
assume_yes=0
confirmed=0

usage() {
  cat <<'EOF'
Usage:
  bash redis-cluster/ensure-zone-replication.sh [--apply] [--yes]

Options:
  --apply  Thực hiện CLUSTER REPLICATE/FAILOVER. Mặc định chỉ dry-run.
  --yes    Không hỏi xác nhận khi dùng --apply.
  -h, --help

Environment:
  KUBE_CONTEXT         kubectl context; mặc định là context hiện tại.
  NAMESPACE            mặc định redis-cluster.
  CLI_POD              pod dùng đọc CLUSTER NODES.
  REPLICATION_TIMEOUT  giây chờ mỗi lần sync/failover; mặc định 300.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --apply) apply=1 ;;
    --yes) assume_yes=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Tham số không hợp lệ: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

command -v kubectl >/dev/null || { echo 'Thiếu kubectl.' >&2; exit 1; }
command -v awk >/dev/null || { echo 'Thiếu awk.' >&2; exit 1; }

kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" -n "$NAMESPACE")

seed_cli() {
  "${kubectl_cmd[@]}" exec "$CLI_POD" -- \
    redis-cli --tls --cacert /tls/ca.crt \
      --sni "$SEED_HOST" -h 127.0.0.1 -p "$REDIS_PORT" "$@"
}

declare -A pod_of=() host_of=() zone_of=() role_of=() master_of=()
declare -a all_ids=() masters=() replicas=() zones=()

load_topology() {
  local nodes node_id addr flags master_id host pod node_name zone id
  local -A zone_seen=()

  pod_of=(); host_of=(); zone_of=(); role_of=(); master_of=()
  all_ids=(); masters=(); replicas=(); zones=()
  nodes="$(seed_cli --raw CLUSTER NODES | tr -d '\r')"

  while read -r node_id addr flags master_id; do
    [[ -n "$node_id" ]] || continue
    if [[ "$flags" == *fail* ]]; then
      echo "Redis node $node_id đang có cờ fail; không tự cân bằng." >&2
      return 1
    fi
    if [[ "$addr" != *,* ]]; then
      echo "Redis node $node_id chưa announce hostname: $addr" >&2
      return 1
    fi

    host="${addr#*,}"
    pod="${host%%.*}"
    node_name="$("${kubectl_cmd[@]}" get pod "$pod" -o jsonpath='{.spec.nodeName}')"
    zone="$("${kubectl_cmd[@]}" get node "$node_name" \
      -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}')"
    [[ -n "$zone" ]] || { echo "Node $node_name chưa có label zone." >&2; return 1; }

    all_ids+=("$node_id")
    pod_of["$node_id"]="$pod"
    host_of["$node_id"]="$host"
    zone_of["$node_id"]="$zone"
    if [[ "$flags" == *master* ]]; then
      role_of["$node_id"]="master"
      master_of["$node_id"]=""
      masters+=("$node_id")
    else
      role_of["$node_id"]="replica"
      master_of["$node_id"]="$master_id"
      replicas+=("$node_id")
    fi
    if [[ -z "${zone_seen[$zone]:-}" ]]; then
      zone_seen["$zone"]=1
      zones+=("$zone")
    fi
  done < <(awk '{print $1, $2, $3, $4}' <<<"$nodes")

  # Thứ tự ổn định giúp kế hoạch dry-run dễ đọc và lặp lại.
  mapfile -t masters < <(
    for id in "${masters[@]}"; do printf '%s\t%s\n' "${pod_of[$id]}" "$id"; done |
      sort | awk '{print $2}'
  )
  mapfile -t replicas < <(
    for id in "${replicas[@]}"; do printf '%s\t%s\n' "${pod_of[$id]}" "$id"; done |
      sort | awk '{print $2}'
  )
  mapfile -t all_ids < <(
    for id in "${all_ids[@]}"; do printf '%s\t%s\n' "${pod_of[$id]}" "$id"; done |
      sort | awk '{print $2}'
  )
  mapfile -t zones < <(printf '%s\n' "${zones[@]}" | sort)
}

node_cli() {
  local id="$1"
  shift
  "${kubectl_cmd[@]}" exec "${pod_of[$id]}" -- \
    redis-cli --tls --cacert /tls/ca.crt \
      --sni "${host_of[$id]}" -h "${host_of[$id]}" -p "$REDIS_PORT" "$@"
}

validate_cluster_health() {
  local info state known slots_ok
  info="$(seed_cli --raw CLUSTER INFO | tr -d '\r')"
  state="$(awk -F: '/^cluster_state:/{print $2}' <<<"$info")"
  known="$(awk -F: '/^cluster_known_nodes:/{print $2}' <<<"$info")"
  slots_ok="$(awk -F: '/^cluster_slots_ok:/{print $2}' <<<"$info")"
  if [[ "$state" != ok || "$known" != 6 || "$slots_ok" != 16384 ]]; then
    echo "Cluster chưa an toàn để đổi role: state=$state nodes=$known slots_ok=$slots_ok (cần ok/6/16384)." >&2
    return 1
  fi
}

zone_counts() {
  local id zone
  declare -gA master_count=() replica_count=() node_count=()
  for zone in "${zones[@]}"; do
    master_count["$zone"]=0
    replica_count["$zone"]=0
    node_count["$zone"]=0
  done
  for id in "${masters[@]}"; do
    zone="${zone_of[$id]}"
    master_count["$zone"]=$(( master_count["$zone"] + 1 ))
    node_count["$zone"]=$(( node_count["$zone"] + 1 ))
  done
  for id in "${replicas[@]}"; do
    zone="${zone_of[$id]}"
    replica_count["$zone"]=$(( replica_count["$zone"] + 1 ))
    node_count["$zone"]=$(( node_count["$zone"] + 1 ))
  done
}

print_zone_counts() {
  local zone
  zone_counts
  printf '%-16s %-8s %-8s\n' ZONE MASTER REPLICA
  for zone in "${zones[@]}"; do
    printf '%-16s %-8s %-8s\n' "$zone" "${master_count[$zone]}" "${replica_count[$zone]}"
  done
}

validate_topology_shape() {
  local zone
  zone_counts
  if (( ${#zones[@]} != 3 || ${#masters[@]} != 3 || ${#replicas[@]} != 3 )); then
    echo 'Cần đúng 3 zone, 3 master và 3 replica; dừng để tránh failover sai.' >&2
    return 1
  fi
  for zone in "${zones[@]}"; do
    if (( node_count[$zone] != 2 )); then
      echo "Zone $zone có ${node_count[$zone]} Redis node, cần đúng 2." >&2
      echo 'Sửa scheduling trước; script chỉ thay đổi role, không di chuyển Pod.' >&2
      return 1
    fi
  done
}

zone_roles_balanced() {
  local zone
  zone_counts
  for zone in "${zones[@]}"; do
    (( master_count[$zone] == 1 && replica_count[$zone] == 1 )) || return 1
  done
}

confirm_apply() {
  local answer
  (( confirmed == 0 )) || return 0
  if (( assume_yes == 0 )); then
    if [[ ! -t 0 ]]; then
      echo 'Không có terminal xác nhận; dùng --apply --yes nếu đã kiểm tra kế hoạch.' >&2
      return 2
    fi
    read -r -p 'Thực hiện kế hoạch trên? [y/N] ' answer
    [[ "$answer" == y || "$answer" == Y ]] || { echo 'Đã hủy.'; exit 0; }
  fi
  confirmed=1
}

choose_role_move() {
  local receiver='' donor='' id current target='' target_replicas best_replicas=999
  zone_counts

  for zone in "${zones[@]}"; do
    if (( master_count[$zone] == 0 )) && [[ -z "$receiver" ]]; then receiver="$zone"; fi
    if (( master_count[$zone] > 1 )) && [[ -z "$donor" ]]; then donor="$zone"; fi
  done
  [[ -n "$receiver" && -n "$donor" ]] || return 1

  ROLE_REPLICA=''
  ROLE_TARGET=''
  ROLE_RECEIVER="$receiver"
  ROLE_DONOR="$donor"

  # Ưu tiên replica đã theo một master trong zone thừa để tránh full sync.
  for id in "${replicas[@]}"; do
    [[ "${zone_of[$id]}" == "$receiver" ]] || continue
    current="${master_of[$id]}"
    if [[ -n "$current" && "${role_of[$current]:-}" == master &&
          "${zone_of[$current]:-}" == "$donor" ]]; then
      ROLE_REPLICA="$id"
      ROLE_TARGET="$current"
      return 0
    fi
  done

  for id in "${replicas[@]}"; do
    if [[ "${zone_of[$id]}" == "$receiver" ]]; then
      ROLE_REPLICA="$id"
      break
    fi
  done
  [[ -n "$ROLE_REPLICA" ]] || return 1

  # Nếu phải đổi upstream, chọn master ít replica nhất trong zone thừa.
  for target in "${masters[@]}"; do
    [[ "${zone_of[$target]}" == "$donor" ]] || continue
    target_replicas=0
    for id in "${replicas[@]}"; do
      [[ "${master_of[$id]}" == "$target" ]] && target_replicas=$((target_replicas + 1))
    done
    if (( target_replicas < best_replicas )); then
      best_replicas=$target_replicas
      ROLE_TARGET="$target"
    fi
  done
  [[ -n "$ROLE_TARGET" ]]
}

wait_replica_sync() {
  local replica="$1" target="$2" deadline info link syncing current observed
  deadline=$((SECONDS + REPLICATION_TIMEOUT))
  while (( SECONDS < deadline )); do
    info="$(node_cli "$replica" --raw INFO replication | tr -d '\r')"
    link="$(awk -F: '/^master_link_status:/{print $2}' <<<"$info")"
    syncing="$(awk -F: '/^master_sync_in_progress:/{print $2}' <<<"$info")"
    current="$(node_cli "$replica" --raw CLUSTER NODES | tr -d '\r' |
      awk -v id="$replica" '$1 == id {print $4}')"
    observed="$(seed_cli --raw CLUSTER NODES | tr -d '\r' |
      awk -v id="$replica" '$1 == id {print $4}')"
    if [[ "$current" == "$target" && "$observed" == "$target" &&
          "$link" == up && "$syncing" == 0 ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

wait_failover() {
  local promoted="$1" demoted="$2" deadline nodes observer_nodes
  local promoted_flags demoted_flags demoted_master
  local observer_promoted_flags observer_demoted_flags observer_demoted_master
  deadline=$((SECONDS + REPLICATION_TIMEOUT))
  while (( SECONDS < deadline )); do
    nodes="$(node_cli "$promoted" --raw CLUSTER NODES | tr -d '\r')"
    promoted_flags="$(awk -v id="$promoted" '$1 == id {print $3}' <<<"$nodes")"
    demoted_flags="$(awk -v id="$demoted" '$1 == id {print $3}' <<<"$nodes")"
    demoted_master="$(awk -v id="$demoted" '$1 == id {print $4}' <<<"$nodes")"
    observer_nodes="$(seed_cli --raw CLUSTER NODES | tr -d '\r')"
    observer_promoted_flags="$(awk -v id="$promoted" '$1 == id {print $3}' <<<"$observer_nodes")"
    observer_demoted_flags="$(awk -v id="$demoted" '$1 == id {print $3}' <<<"$observer_nodes")"
    observer_demoted_master="$(awk -v id="$demoted" '$1 == id {print $4}' <<<"$observer_nodes")"
    if [[ "$promoted_flags" == *master* && "$promoted_flags" != *fail* &&
          "$demoted_flags" != *master* && "$demoted_flags" != *fail* &&
          "$demoted_master" == "$promoted" &&
          "$observer_promoted_flags" == *master* && "$observer_promoted_flags" != *fail* &&
          "$observer_demoted_flags" != *master* && "$observer_demoted_flags" != *fail* &&
          "$observer_demoted_master" == "$promoted" ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

print_role_plan() {
  local step=0 replica target current
  local -A saved_role=() saved_master=()
  local id

  # Dry-run nhiều bước bằng cách mô phỏng; khi apply, topology sẽ được
  # đọc lại sau từng failover thay vì tin tuyệt đối vào mô phỏng này.
  for id in "${all_ids[@]}"; do
    saved_role[$id]="${role_of[$id]}"
    saved_master[$id]="${master_of[$id]}"
  done

  echo
  echo 'Kế hoạch cân bằng role giữa các zone:'
  while ! zone_roles_balanced; do
    choose_role_move || { echo 'Không lập được kế hoạch chuyển role an toàn.' >&2; return 1; }
    step=$((step + 1))
    replica="$ROLE_REPLICA"
    target="$ROLE_TARGET"
    current="${master_of[$replica]}"
    printf '  Bước %d: %s (%s) -> master; %s (%s) -> replica\n' \
      "$step" "${pod_of[$replica]}" "$ROLE_RECEIVER" \
      "${pod_of[$target]}" "$ROLE_DONOR"
    if [[ "$current" != "$target" ]]; then
      printf '           CLUSTER REPLICATE %s, chờ sync, sau đó CLUSTER FAILOVER\n' \
        "${pod_of[$target]}"
    else
      echo '           Giữ upstream hiện tại, sau đó CLUSTER FAILOVER'
    fi

    role_of[$replica]=master
    master_of[$replica]=''
    role_of[$target]=replica
    master_of[$target]="$replica"
    masters=(); replicas=()
    for id in "${all_ids[@]}"; do
      if [[ "${role_of[$id]}" == master ]]; then masters+=("$id"); else replicas+=("$id"); fi
    done
    (( step < 3 )) || zone_roles_balanced || {
      echo 'Kế hoạch cân bằng role vượt quá số bước an toàn.' >&2
      return 1
    }
  done

  role_of=(); master_of=(); masters=(); replicas=()
  for id in "${all_ids[@]}"; do
    role_of[$id]="${saved_role[$id]}"
    master_of[$id]="${saved_master[$id]}"
    if [[ "${role_of[$id]}" == master ]]; then masters+=("$id"); else replicas+=("$id"); fi
  done
}

apply_role_balance() {
  local replica target current steps=0
  while ! zone_roles_balanced; do
    choose_role_move || { echo 'Topology đã thay đổi; không chọn được cặp failover an toàn.' >&2; return 1; }
    replica="$ROLE_REPLICA"
    target="$ROLE_TARGET"
    current="${master_of[$replica]}"
    steps=$((steps + 1))

    echo
    echo "Cân bằng role: ${pod_of[$replica]} ($ROLE_RECEIVER) lên master; ${pod_of[$target]} ($ROLE_DONOR) xuống replica"
    if [[ "$current" != "$target" ]]; then
      echo "Đổi ${pod_of[$replica]} sang replicate ${pod_of[$target]} và chờ đồng bộ..."
      node_cli "$replica" CLUSTER REPLICATE "$target"
      if ! wait_replica_sync "$replica" "$target"; then
        echo "Timeout chờ ${pod_of[$replica]} đồng bộ; không thực hiện failover." >&2
        return 1
      fi
    fi

    echo "Failover có kiểm soát trên ${pod_of[$replica]}..."
    node_cli "$replica" CLUSTER FAILOVER
    if ! wait_failover "$replica" "$target"; then
      echo "Timeout chờ failover ${pod_of[$replica]}; dừng trước thay đổi tiếp theo." >&2
      return 1
    fi
    echo "OK: ${pod_of[$replica]} đã lên master; ${pod_of[$target]} đã xuống replica."

    load_topology
    validate_cluster_health
    validate_topology_shape
    (( steps < 3 )) || zone_roles_balanced || {
      echo 'Không cân bằng được role sau 3 bước; dừng.' >&2
      return 1
    }
  done
}

load_topology
echo "Context: $KUBE_CONTEXT | namespace: $NAMESPACE"
validate_cluster_health
print_zone_counts
validate_topology_shape

role_changed=0
if ! zone_roles_balanced; then
  print_role_plan
  echo
  echo 'Mỗi bước có thể full sync replica trước khi failover có kiểm soát.'
  if (( apply == 0 )); then
    echo 'Dry-run: chạy lại với --apply để cân bằng role; script sẽ đọc lại topology sau từng bước.'
    echo 'Sau khi role đã cân bằng, script sẽ tự lập và thực hiện kế hoạch ghép replica khác zone nếu cần.'
    exit 0
  fi
  confirm_apply
  apply_role_balance
  role_changed=1
  echo
  echo 'Phân bố role sau failover:'
  print_zone_counts
fi

# Duyệt 3! phép ghép replica -> master, loại cặp cùng zone và chọn phương án
# giữ được nhiều quan hệ replication hiện tại nhất để giảm số lần full sync.
r0="${replicas[0]}"; r1="${replicas[1]}"; r2="${replicas[2]}"
best_score=-1
best0=""; best1=""; best2=""
for m0 in "${masters[@]}"; do
  for m1 in "${masters[@]}"; do
    [[ "$m1" != "$m0" ]] || continue
    for m2 in "${masters[@]}"; do
      [[ "$m2" != "$m0" && "$m2" != "$m1" ]] || continue
      [[ "${zone_of[$r0]}" != "${zone_of[$m0]}" ]] || continue
      [[ "${zone_of[$r1]}" != "${zone_of[$m1]}" ]] || continue
      [[ "${zone_of[$r2]}" != "${zone_of[$m2]}" ]] || continue
      score=0
      [[ "${master_of[$r0]}" == "$m0" ]] && score=$((score + 1))
      [[ "${master_of[$r1]}" == "$m1" ]] && score=$((score + 1))
      [[ "${master_of[$r2]}" == "$m2" ]] && score=$((score + 1))
      if (( score > best_score )); then
        best_score=$score
        best0="$m0"; best1="$m1"; best2="$m2"
      fi
    done
  done
done

if (( best_score < 0 )); then
  echo 'Không tìm được phép ghép replica -> master khác zone.' >&2
  exit 1
fi

targets=("$best0" "$best1" "$best2")
changes=0
echo
printf '%-34s %-8s %-34s %-8s %-34s %-8s %s\n' \
  REPLICA R-ZONE CURRENT_MASTER M-ZONE TARGET_MASTER T-ZONE ACTION
for i in 0 1 2; do
  r="${replicas[$i]}"
  current="${master_of[$r]}"
  target="${targets[$i]}"
  current_pod='none'
  current_zone='-'
  if [[ -n "$current" ]]; then
    current_pod="${pod_of[$current]:-unknown}"
    current_zone="${zone_of[$current]:-unknown}"
  fi
  action='keep'
  if [[ "$current" != "$target" ]]; then
    action='replicate'
    changes=$((changes + 1))
  fi
  printf '%-34s %-8s %-34s %-8s %-34s %-8s %s\n' \
    "${pod_of[$r]}" "${zone_of[$r]}" \
    "$current_pod" "$current_zone" \
    "${pod_of[$target]}" "${zone_of[$target]}" "$action"
done

if (( changes == 0 )); then
  echo
  echo 'Không cần thay đổi: mỗi master đã có đúng 1 replica ở zone khác.'
  if (( role_changed )); then
    echo
    echo 'Kiểm tra topology sau thay đổi:'
    KUBE_CONTEXT="$KUBE_CONTEXT" NAMESPACE="$NAMESPACE" \
      bash "$(dirname "$0")/check-cluster.sh"
  fi
  exit 0
fi

echo
echo "Cần đổi $changes quan hệ replication. Mỗi replica có thể thực hiện full sync."
if (( apply == 0 )); then
  echo 'Dry-run: chạy lại với --apply để thực hiện.'
  exit 0
fi

confirm_apply

for i in 0 1 2; do
  r="${replicas[$i]}"
  target="${targets[$i]}"
  [[ "${master_of[$r]}" != "$target" ]] || continue

  echo
  echo "Đổi ${pod_of[$r]} (${zone_of[$r]}) -> ${pod_of[$target]} (${zone_of[$target]})"
  node_cli "$r" CLUSTER REPLICATE "$target"
  if ! wait_replica_sync "$r" "$target"; then
    echo "Timeout chờ ${pod_of[$r]} đồng bộ; dừng trước thay đổi tiếp theo." >&2
    exit 1
  fi
  echo "OK: ${pod_of[$r]} đã đồng bộ với ${pod_of[$target]}."
done

echo
echo 'Kiểm tra topology sau thay đổi:'
KUBE_CONTEXT="$KUBE_CONTEXT" NAMESPACE="$NAMESPACE" \
  bash "$(dirname "$0")/check-cluster.sh"
