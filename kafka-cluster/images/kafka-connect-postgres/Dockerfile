# Image Kafka Connect cho Strimzi, bổ sung plugin Debezium PostgreSQL.
# Strimzi chạy Kafka từ /opt/kafka và nạp plugin từ /opt/kafka/plugins, nên image nền
# phải là quay.io/strimzi/kafka. Image connect-base của Debezium dùng đường dẫn /kafka
# khác và không khởi động đúng khi Strimzi quản lý Pod.
ARG STRIMZI_VERSION=1.3.0
ARG KAFKA_VERSION=4.3.1
ARG DEBEZIUM_VERSION=3.5.2.Final

# Lấy thư mục plugin đã đóng gói sẵn (connector và các jar phụ thuộc) từ image Debezium Connect.
FROM quay.io/debezium/connect:${DEBEZIUM_VERSION} AS debezium-connect-full

FROM quay.io/strimzi/kafka:${STRIMZI_VERSION}-kafka-${KAFKA_VERSION}

USER root

COPY --from=debezium-connect-full --chown=1001:0 \
  /kafka/connect/debezium-connector-postgres/ \
  /opt/kafka/plugins/debezium-connector-postgres/

# UID 1001 là user kafka của image Strimzi.
USER 1001
