# Thêm vào entrypoint của image opstree/redis. Redis Cluster announce hostname này cho client và
# các node khác (CLUSTER NODES, CLUSTER SLOTS, MOVED), nên phải là FQDN resolve được từ mọi namespace.
# Tên Pod có dạng <role>-<ordinal> và thuộc Service headless <role>-headless (operator đặt spec.subdomain).
announce_fqdn() {
  local pod sub
  pod="$(hostname)"
  sub="${pod%-*}-headless"
  if [[ -z "${POD_NAMESPACE:-}" ]]; then
    echo "POD_NAMESPACE is required" >&2
    exit 1
  fi
  echo "${pod}.${sub}.${POD_NAMESPACE}.svc.${CLUSTER_DOMAIN:-cluster.local}"
}
