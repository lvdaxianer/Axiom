#!/bin/sh
set -eu

HOST_VECTOR_DIR="${HOST_VECTOR_DIR:-/host-vector}"
HOST_CONFIG_DIR="${HOST_VECTOR_DIR}/config"
HOST_DATA_DIR="${HOST_VECTOR_DIR}/data"
BOOTSTRAP_CONFIG="${BOOTSTRAP_CONFIG:-/bootstrap-config/vector.toml}"
HOST_CONFIG_FILE="${HOST_CONFIG_FILE:-${HOST_CONFIG_DIR}/vector.toml}"

# 初始化宿主机持久化目录，确保配置和 checkpoint 有稳定落点。
mkdir -p "${HOST_CONFIG_DIR}" "${HOST_DATA_DIR}"

# 仅在宿主机没有配置时写入默认模板，保留现场人工修改的配置。
if [ ! -s "${HOST_CONFIG_FILE}" ]; then
  cp "${BOOTSTRAP_CONFIG}" "${HOST_CONFIG_FILE}"
fi

# 始终使用宿主机上的配置启动 Vector，便于现场直接调整。
exec vector --config "${HOST_CONFIG_FILE}"
