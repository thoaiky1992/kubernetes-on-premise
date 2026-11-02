# Redis Cluster node: image opstree chính thức + entrypoint announce FQDN thay vì tên Pod ngắn.
# Base image được pin theo phiên bản; không đổi tag mà không kiểm tra lại CLUSTER NODES và TLS.
FROM quay.io/opstree/redis:v7.0.15

COPY announce-fqdn.sh /build/announce-fqdn.sh

USER root

# Chèn hàm announce_fqdn ngay sau shebang và đổi dòng POD_HOSTNAME. Build thất bại nếu dòng gốc không khớp,
# để không âm thầm giữ lại hostname ngắn.
RUN set -eux; \
    ep=/usr/bin/entrypoint.sh; \
    grep -q '^        POD_HOSTNAME=\$(hostname)$' "$ep"; \
    sed -i 's/^        POD_HOSTNAME=\$(hostname)$/        POD_HOSTNAME=$(announce_fqdn)/' "$ep"; \
    { head -n 1 "$ep"; cat /build/announce-fqdn.sh; tail -n +2 "$ep"; } > /tmp/entrypoint.new; \
    cat /tmp/entrypoint.new > "$ep"; \
    rm -f /tmp/entrypoint.new; \
    bash -n "$ep"; \
    grep -q 'POD_HOSTNAME=$(announce_fqdn)' "$ep"; \
    rm -rf /build

# Trả về user không phải root như image gốc (1000). Entrypoint vẫn là /usr/bin/entrypoint.sh.
USER 1000
