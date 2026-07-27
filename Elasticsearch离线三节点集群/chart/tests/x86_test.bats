#!/usr/bin/env bats
# 文件说明：验证 x86_64 values 覆盖可复用 ARM fixture 的其余部署参数。
# x86 覆盖只替换镜像身份和节点架构，网络、快照和安全参数仍来自 fixture。

setup() {
  # Args: 无，使用 Bats 注入的测试目录。
  # Returns: 设置 Chart、ARM fixture 和 x86 覆盖文件路径。
  # Author: lvdaxianer@yeah.net
  # Date: 2026-07-27
  # 从测试目录定位 Chart、完整有效 fixture 和 x86 镜像覆盖文件。
  CHART_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_DIRNAME/fixtures/valid-values.yaml"
  X86_VALUES="$CHART_DIR/values.x86.yaml"
}

@test "x86 overlay renders the amd64 digest-pinned image" {
  # 组合 ARM fixture 的通用部署参数和 x86 专用镜像/调度参数。
  run helm template es-cluster "$CHART_DIR" -n uino \
    -f "$FIXTURE" -f "$X86_VALUES"

  # x86 overlay 必须通过 schema，并渲染精确的 digest 镜像和 amd64 选择器。
  [ "$status" -eq 0 ]
  [[ "$output" == *"10.100.30.139/library/elasticsearch:7.10.2@sha256:cce094529ca2f542ece2e52354763d9b1beb56458982b35b13fab7035c861910"* ]]
  [[ "$output" == *"kubernetes.io/arch: amd64"* ]]
}

@test "schema rejects mixed image and worker architectures" {
  # x86 tag 与 ARM64 节点混用时必须在 Helm schema 阶段失败。
  run helm template es-cluster "$CHART_DIR" -n uino \
    -f "$FIXTURE" \
    --set-string image.tag=7.10.2 \
    --set-string 'nodeSelector.kubernetes\.io/arch=arm64'
  [ "$status" -ne 0 ]

  # ARM64 tag 与 AMD64 节点混用时同样必须被拒绝。
  run helm template es-cluster "$CHART_DIR" -n uino \
    -f "$FIXTURE" \
    --set-string image.tag=7.10.2-arm64-hardened \
    --set-string 'nodeSelector.kubernetes\.io/arch=amd64'
  [ "$status" -ne 0 ]
}
