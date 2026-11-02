# Project guide

This repository deploys a six-node on-premise Kubernetes stack. Start with `README.md` for kubeadm, Cilium, local PV and install order. Runbooks are in Vietnamese. Use an explicit `KUBE_CONTEXT` for every cluster write.

Architecture: 3 schedulable control-plane/etcd nodes and 3 workers, 2 nodes in each of three physical zones. ECK Elasticsearch and Strimzi Kafka each have 6 pods, one per host. Redis Cluster has 3 leaders and 3 followers. Each component directory owns its `storage-class.yaml`, `pv.yaml`, and `pvc.yaml`; storage does not migrate automatically when a host fails. Operator-managed workloads create their data PVCs from CR templates. Kibana and RedisInsight are available through port-forward by default.

Secret templates are `*.example`; copy to real files locally and never commit secrets or private keys. Cross-namespace CA distribution is manual: app copies public `ca.crt` from Elasticsearch and Redis; RedisInsight copies only Redis CA. Do not disable TLS verification or hostname checks.

Custom images: Redis FQDN node image, Redis backup image, Kafka Connect PostgreSQL image, and Node API image. Build/push them to a registry reachable by all six nodes, then keep manifest tags in sync. Redis backup writes to a local PV on cp1; copy it off-cluster and test restore. Elasticsearch needs a shared repository outside the data PVs for snapshots. Kafka requires its own off-cluster recovery plan.

Useful checks:

```bash
export KUBE_CONTEXT="$(kubectl config current-context)"
KUBE_CONTEXT="$KUBE_CONTEXT" bash elasticsearch/check.sh
KUBE_CONTEXT="$KUBE_CONTEXT" bash redis-cluster/check-cluster.sh
KUBE_CONTEXT="$KUBE_CONTEXT" bash kafka-cluster/check.sh
kubectl --context "$KUBE_CONTEXT" get pv,pvc -A
```
