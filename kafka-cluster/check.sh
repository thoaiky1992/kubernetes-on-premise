#!/usr/bin/env bash
set -euo pipefail
KUBE_CONTEXT="${KUBE_CONTEXT:-$(kubectl config current-context)}"
command -v jq >/dev/null || { echo 'Thiếu jq' >&2; exit 1; }
kubectl_cmd=(kubectl --context "$KUBE_CONTEXT" --request-timeout=20s)
nodes_json="$("${kubectl_cmd[@]}" get nodes -o json)"
jq -e '(.items | length == 6) and ([.items[] | select(.spec.unschedulable != true) | select(any(.status.conditions[]; .type == "Ready" and .status == "True")) | select(all(.spec.taints[]?; .effect != "NoSchedule" and .effect != "NoExecute"))] | length == 6)' <<<"$nodes_json" >/dev/null || { echo 'Cần đúng 6 node Ready, không cordon hoặc taint NoSchedule/NoExecute.' >&2; exit 1; }
jq -e '[.items[].metadata.labels["topology.kubernetes.io/zone"]] | all(. != null) and (group_by(.) | length == 3 and all(length == 2))' <<<"$nodes_json" >/dev/null || { echo 'Cần 3 zone, mỗi zone 2 node.' >&2; exit 1; }
"${kubectl_cmd[@]}" get storageclass local-kafka >/dev/null
pv_count="$("${kubectl_cmd[@]}" get pv -o json | jq '[.items[] | select(.spec.storageClassName == "local-kafka")] | length')"
(( pv_count >= 6 )) || { echo 'Cần ít nhất 6 local PV Kafka.' >&2; exit 1; }
echo "Kafka preflight OK: 6 node, 3 zone, $pv_count local PV."
