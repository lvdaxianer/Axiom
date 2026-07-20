#!/usr/bin/env python3
"""校验 Elasticsearch 核心 Helm 资源和 X.509 身份材料。

Args:
    无，通过命令行接收断言模式和渲染文件。
Returns:
    模块本身无返回值。
Author: lvdaxianer@yeah.net
Date: 2026-07-21
"""

import base64
import sys
from typing import Any, Callable

from cryptography import x509

from assert_common import documents, fail, named, one

EXPECTED_IMAGE = (
    "registry.internal.example/uino/elasticsearch:7.10.2-arm64-hardened@sha256:"
    + "1" * 64
)


def env_map(container: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """将容器环境变量转换为名称索引。
    Args:
        container: Kubernetes 容器定义。
    Returns:
        环境变量名称到定义的映射。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    return {item["name"]: item for item in container.get("env", [])}


def assert_core_kinds(items: list[dict[str, Any]]) -> None:
    """校验核心资源类型和最小数量。
    Args:
        items: Kubernetes 资源列表。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    kinds = [item["kind"] for item in items]
    for kind in (
        "ConfigMap",
        "Service",
        "Secret",
        "StatefulSet",
        "PodDisruptionBudget",
    ):
        assert kinds.count(kind) >= (2 if kind == "Service" else 1), (kind, kinds)


def assert_headless(service: dict[str, Any]) -> None:
    """校验无头发现 Service 的端口和发布行为。
    Args:
        service: 无头 Service 资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert service["spec"]["clusterIP"] == "None"
    assert service["spec"]["publishNotReadyAddresses"] is True
    assert {port["name"] for port in service["spec"]["ports"]} == {"http", "transport"}


def assert_statefulset(
    statefulset: dict[str, Any], service_name: str
) -> dict[str, Any]:
    """校验 StatefulSet 发布策略并返回 PodSpec。
    Args:
        statefulset: StatefulSet 资源；service_name: 无头 Service 名称。
    Returns:
        StatefulSet 的 PodSpec。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    spec = statefulset["spec"]
    assert spec["replicas"] == 3 and spec["podManagementPolicy"] == "Parallel"
    assert (
        spec["updateStrategy"]["type"] == "RollingUpdate"
        and spec["serviceName"] == service_name
    )
    assert "volumeClaimTemplates" not in spec
    return spec["template"]["spec"]


def assert_pod_policy(pod: dict[str, Any]) -> None:
    """校验 Pod 调度、身份和终止策略。
    Args:
        pod: Kubernetes PodSpec。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    required = pod["affinity"]["podAntiAffinity"][
        "requiredDuringSchedulingIgnoredDuringExecution"
    ]
    assert pod["terminationGracePeriodSeconds"] == 120 and len(required) == 1
    assert required[0]["topologyKey"] == "kubernetes.io/hostname"
    assert pod["nodeSelector"] == {"kubernetes.io/arch": "arm64"}
    assert pod["imagePullSecrets"] == [{"name": "registry-credentials"}]
    assert pod["securityContext"]["fsGroup"] == 1000


def assert_data_init(pod: dict[str, Any]) -> None:
    """校验 Pod 独立数据目录和受控初始化逻辑。
    Args:
        pod: Kubernetes PodSpec。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    data = named(pod["volumes"], "data")
    assert data["hostPath"] == {"path": "/data/uinnova/apps/es", "type": "Directory"}
    prepare = named(pod["initContainers"], "prepare")
    assert prepare["securityContext"] == {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000}  # fmt: skip
    script = " ".join(prepare["command"] + prepare.get("args", []))
    assert all(token in script for token in ("POD_NAME", "/mnt/es-data/${POD_NAME}", "mkdir", "nodes/0/_state", "global-*.st"))  # fmt: skip
    assert all(token not in script for token in ("chown", "chmod", "rm -rf"))


def assert_container(container: dict[str, Any], service_name: str) -> None:
    """校验 Elasticsearch 容器镜像、挂载和安全变量。
    Args:
        container: 容器定义；service_name: 无头 Service 名称。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert container["image"] == EXPECTED_IMAGE and container["imagePullPolicy"] == "IfNotPresent"  # fmt: skip
    assert named(container["volumeMounts"], "data")["subPathExpr"] == "$(POD_NAME)"
    env = env_map(container)
    assert env["node.roles"]["value"] == "master,data,ingest"
    assert env["discovery.seed_hosts"]["value"] == service_name
    assert env["ES_JAVA_OPTS"]["value"] == "-Xms4g -Xmx4g"
    assert all(env[key]["value"] == "true" for key in ("xpack.security.enabled", "xpack.security.transport.ssl.enabled", "xpack.security.http.ssl.enabled"))  # fmt: skip
    assert env["ELASTIC_PASSWORD"]["valueFrom"]["secretKeyRef"]["key"] == "elastic-password"  # fmt: skip


def assert_probe(probe: dict[str, Any], is_readiness: bool = False) -> None:
    """校验 HTTPS 探针及可选就绪条件。
    Args:
        probe: Kubernetes 探针定义；is_readiness: 是否校验集群就绪请求。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    command = " ".join(probe["exec"]["command"])
    assert "https://127.0.0.1:9200" in command and "--cacert" in command
    # 就绪探针还必须等待集群达到 yellow，启动和存活探针无需该条件。
    if is_readiness:
        assert "_cluster/health?wait_for_status=yellow&timeout=1s" in command


def assert_runtime(container: dict[str, Any]) -> None:
    """校验容器资源限制和运行探针。
    Args:
        container: Elasticsearch 容器定义。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert container["resources"] == {
        "requests": {"cpu": "2", "memory": "8Gi"},
        "limits": {"cpu": "4", "memory": "8Gi"},
    }
    assert_probe(container["startupProbe"])
    assert_probe(container["readinessProbe"], True)
    assert_probe(container["livenessProbe"])
    assert container["startupProbe"]["failureThreshold"] >= 30


def assert_tls_sans(secret: dict[str, Any], service_ip: str) -> None:
    """校验 TLS 证书的 Service DNS 和固定 IP SAN。
    Args:
        secret: TLS Secret；service_ip: 期望的固定服务 IP。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    cert = x509.load_pem_x509_certificate(base64.b64decode(secret["data"]["tls.crt"]))
    names = cert.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    dns = set(names.get_values_for_type(x509.DNSName))
    ips = {str(value) for value in names.get_values_for_type(x509.IPAddress)}
    fullname = "es-cluster-uino-elasticsearch"
    assert {fullname, f"{fullname}.uino.svc"} <= dns and "127.0.0.1" in ips
    assert (service_ip in ips) is bool(service_ip)


def assert_secrets(items: list[dict[str, Any]]) -> None:
    """校验托管 Secret 的保留策略、键和证书 SAN。
    Args:
        items: Kubernetes 资源列表。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    secrets = [item for item in items if item["kind"] == "Secret"]
    assert all(secret["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep" for secret in secrets)  # fmt: skip
    credentials = next(secret for secret in secrets if "elastic-password" in secret.get("data", {}))  # fmt: skip
    tls = next(secret for secret in secrets if "tls.crt" in secret.get("data", {}))
    assert credentials["data"]["elastic-password"] and {"tls.crt", "tls.key", "ca.crt"} <= set(tls["data"])  # fmt: skip
    assert_tls_sans(tls, "192.0.2.50")


def assert_config(items: list[dict[str, Any]]) -> None:
    """校验 Elasticsearch 静态安全配置。
    Args:
        items: Kubernetes 资源列表。
    Returns: 无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    config = one(items, "ConfigMap")["data"]["elasticsearch.yml"]
    assert "cluster.initial_master_nodes" not in config
    assert all(
        value in config
        for value in (
            "xpack.security.enabled: true",
            "xpack.security.transport.ssl.enabled: true",
            "xpack.security.http.ssl.enabled: true",
        )
    )


def assert_core(items: list[dict[str, Any]]) -> None:
    """组合执行全部核心集群断言。
    Args:
        items: Kubernetes 资源列表。
    Returns: 无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert_core_kinds(items)
    headless = one(items, "Service", "es-cluster-uino-elasticsearch-headless")
    pod = assert_statefulset(one(items, "StatefulSet"), headless["metadata"]["name"])
    assert_headless(headless)
    assert_pod_policy(pod)
    assert_data_init(pod)
    container = named(pod["containers"], "elasticsearch")
    assert_container(container, headless["metadata"]["name"])
    assert_runtime(container)
    assert one(items, "PodDisruptionBudget")["spec"]["minAvailable"] == 2
    assert_secrets(items)
    assert_config(items)


def assert_tls_service_ip(items: list[dict[str, Any]]) -> None:
    """确认核心证书使用 Service 固定 IP。
    Args:
        items: Helm 渲染资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    tls = next(
        item
        for item in items
        if item["kind"] == "Secret" and "tls.crt" in item.get("data", {})
    )
    assert_tls_sans(tls, "192.0.2.50")


def assert_existing_secrets(items: list[dict[str, Any]]) -> None:
    """校验外部 Secret 模式只引用既有对象。
    Args:
        items: Kubernetes 资源列表。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert not [item for item in items if item["kind"] == "Secret"]
    pod = one(items, "StatefulSet")["spec"]["template"]["spec"]
    container = named(pod["containers"], "elasticsearch")
    ref = env_map(container)["ELASTIC_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert ref["name"] == "managed-es-credentials"
    mount = named(container["volumeMounts"], "tls")
    volume = named(pod["volumes"], mount["name"])
    assert volume["secret"]["secretName"] == "managed-es-tls"


def parse_args() -> tuple[str, str]:
    """解析断言模式和渲染文件路径。
    Args:
        无，读取命令行参数。
    Returns:
        模式和文件路径。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    # 参数数量不完整时拒绝猜测模式或输入文件。
    if len(sys.argv) != 3:
        fail("usage: assert_render.py <mode> <rendered.yaml>")
    return sys.argv[1], sys.argv[2]


def main() -> None:
    """选择并执行核心资源断言集。
    Args:
        无，读取命令行参数。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    mode, path = parse_args()
    handlers: dict[str, Callable[[list[dict[str, Any]]], None]] = {
        "core": assert_core,
        "tls-service-ip": assert_tls_service_ip,
        "existing-secrets": assert_existing_secrets,
    }
    # 未注册模式不能静默降级到其他断言集。
    if mode not in handlers:
        fail(f"unknown mode: {mode}")
    handlers[mode](documents(path))


# 仅直接执行脚本时启动命令行断言，导入共享函数时保持无副作用。
if __name__ == "__main__":
    main()
