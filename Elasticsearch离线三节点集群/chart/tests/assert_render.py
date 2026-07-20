#!/usr/bin/env python3
"""Helm 渲染结果的结构化断言。"""
import base64
import sys
from typing import Any, Callable

import yaml
from cryptography import x509

REQUIRED_KIND_COUNTS = {"ConfigMap": 1, "Service": 1, "Secret": 2, "StatefulSet": 1, "PodDisruptionBudget": 1}
EXPECTED_IMAGE = "registry.internal.example/uino/elasticsearch:7.10.2-arm64-hardened@sha256:" + "1" * 64

def fail(message: str) -> None:
    """抛出带上下文的断言错误。
    Args: message: 错误说明。
    Returns: 不返回，始终抛出异常。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    raise AssertionError(message)
def documents(path: str) -> list[dict[str, Any]]:
    """读取非空 YAML 文档。
    Args: path: Helm 渲染文件路径。
    Returns: 非空 Kubernetes 文档列表。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    with open(path, encoding="utf-8") as stream:
        return [document for document in yaml.safe_load_all(stream) if document]
def one(items: list[dict[str, Any]], kind: str, name: str = "") -> dict[str, Any]:
    """按资源类型和可选名称查找唯一文档。
    Args: items: 文档列表；kind: 资源类型；name: 可选资源名。
    Returns: 唯一匹配的资源文档。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    matches = [item for item in items if item.get("kind") == kind]
    # 指定名称时继续收窄匹配范围。
    if name:
        matches = [item for item in matches if item["metadata"]["name"] == name]
    # 唯一性不满足时输出实际数量，便于定位模板漂移。
    if len(matches) != 1:
        fail(f"expected one {kind} {name}, found {len(matches)}")
    return matches[0]
def named(items: list[dict[str, Any]], key: str, name: str) -> dict[str, Any]:
    """按 name 字段查找唯一子资源。
    Args: items: 子资源列表；key: 用于错误说明的类型；name: 目标名称。
    Returns: 唯一匹配的子资源。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    matches = [item for item in items if item["name"] == name]
    # 唯一性不满足说明模板缺失或重复声明。
    if len(matches) != 1:
        fail(f"expected one {key} {name}, found {len(matches)}")
    return matches[0]
def env_map(container: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """将容器环境变量转换为名称索引。
    Args: container: Kubernetes 容器定义。
    Returns: 环境变量名称到定义的映射。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    return {item["name"]: item for item in container.get("env", [])}
def assert_resource_set(items: list[dict[str, Any]]) -> None:
    """校验渲染结果包含全部核心资源。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    kinds = [item["kind"] for item in items]
    for kind, count in REQUIRED_KIND_COUNTS.items():
        assert kinds.count(kind) >= count, (kind, kinds)
def headless_service(items: list[dict[str, Any]]) -> dict[str, Any]:
    """查找唯一无头核心 Service。

    Args: items: Kubernetes 文档列表。
    Returns: clusterIP 为 None 的核心 Service。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    services = [item for item in items if item["kind"] == "Service" and item["metadata"]["name"].endswith("-headless") and item["spec"].get("clusterIP") == "None"]
    assert len(services) == 1, services
    return services[0]
def assert_service(service: dict[str, Any]) -> None:
    """校验稳定的无头发现服务。

    Args: service: Service 文档。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    spec = service["spec"]
    assert spec["clusterIP"] == "None"
    assert spec["publishNotReadyAddresses"] is True
    assert {port["name"] for port in spec["ports"]} == {"http", "transport"}
def assert_statefulset_policy(statefulset: dict[str, Any], service_name: str) -> None:
    """校验 StatefulSet 的副本和发布策略。

    Args: statefulset: StatefulSet 文档；service_name: 无头服务名称。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    spec = statefulset["spec"]
    assert spec["replicas"] == 3
    assert spec["podManagementPolicy"] == "Parallel"
    assert spec["updateStrategy"]["type"] == "RollingUpdate"
    assert spec["serviceName"] == service_name
    assert "volumeClaimTemplates" not in spec
def assert_pod_policy(pod: dict[str, Any]) -> None:
    """校验 Pod 终止时间和强制反亲和性。

    Args: pod: PodSpec 文档。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert pod["terminationGracePeriodSeconds"] == 120
    anti_affinity = pod["affinity"]["podAntiAffinity"]
    required = anti_affinity["requiredDuringSchedulingIgnoredDuringExecution"]
    assert len(required) == 1
    assert required[0]["topologyKey"] == "kubernetes.io/hostname"
    assert pod["nodeSelector"] == {"kubernetes.io/arch": "arm64"}
    assert pod["imagePullSecrets"] == [{"name": "registry-credentials"}]
    assert pod["securityContext"]["fsGroup"] == 1000
def assert_data_init(pod: dict[str, Any]) -> None:
    """校验每 Pod 数据目录和受控引导逻辑。

    Args: pod: PodSpec 文档。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    data_volume = named(pod["volumes"], "volume", "data")
    assert data_volume["hostPath"] == {"path": "/data/uinnova/apps/es", "type": "Directory"}
    prepare = named(pod["initContainers"], "init container", "prepare")
    assert prepare["securityContext"] == {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000}
    script = " ".join(prepare["command"] + prepare.get("args", []))
    assert "POD_NAME" in script and "/mnt/es-data/${POD_NAME}" in script
    assert "mkdir" in script and "nodes/0/_state" in script
    assert "global-*.st" in script and "cluster.initial_master_nodes" in script
    assert "chown" not in script and "chmod" not in script
    assert "rm -rf" not in script
def assert_image_and_mount(container: dict[str, Any]) -> None:
    """校验镜像摘要和数据子目录挂载。

    Args: container: Elasticsearch 容器定义。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert container["image"] == EXPECTED_IMAGE
    assert container["imagePullPolicy"] == "IfNotPresent"
    data_mount = named(container["volumeMounts"], "volume mount", "data")
    assert data_mount["subPathExpr"] == "$(POD_NAME)"
def assert_security_env(container: dict[str, Any], service_name: str) -> None:
    """校验节点角色、发现、堆和安全环境变量。

    Args: container: 容器定义；service_name: 无头服务名称。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    env = env_map(container)
    assert env["node.roles"]["value"] == "master,data,ingest"
    assert env["discovery.seed_hosts"]["value"] == service_name
    assert env["ES_JAVA_OPTS"]["value"] == "-Xms4g -Xmx4g"
    assert env["xpack.security.enabled"]["value"] == "true"
    assert env["xpack.security.transport.ssl.enabled"]["value"] == "true"
    assert env["xpack.security.http.ssl.enabled"]["value"] == "true"
    password_ref = env["ELASTIC_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert password_ref["key"] == "elastic-password"
def assert_probe(container: dict[str, Any], probe_name: str) -> None:
    """校验单个 HTTPS 探针使用集群 CA。

    Args: container: 容器定义；probe_name: 探针字段名。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    probe = container[probe_name]
    command = " ".join(probe["exec"]["command"])
    assert "https://127.0.0.1:9200" in command
    assert "--cacert" in command
    if probe_name == "readinessProbe":
        assert "_cluster/health?wait_for_status=yellow&timeout=1s" in command
def assert_runtime(container: dict[str, Any]) -> None:
    """校验资源配置和三个运行探针。

    Args: container: Elasticsearch 容器定义。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    expected = {"requests": {"cpu": "2", "memory": "8Gi"}, "limits": {"cpu": "4", "memory": "8Gi"}}
    assert container["resources"] == expected
    for probe_name in ("startupProbe", "readinessProbe", "livenessProbe"):
        assert_probe(container, probe_name)
    assert container["startupProbe"]["failureThreshold"] >= 30
def assert_secrets(items: list[dict[str, Any]]) -> None:
    """校验生成 Secret 的保留策略和键。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    secrets = [item for item in items if item["kind"] == "Secret"]
    assert all(secret["metadata"]["annotations"]["helm.sh/resource-policy"] == "keep" for secret in secrets)
    credentials = next(secret for secret in secrets if "elastic-password" in secret.get("data", {}))
    tls = next(secret for secret in secrets if "tls.crt" in secret.get("data", {}))
    assert credentials["data"]["elastic-password"]
    assert {"tls.crt", "tls.key", "ca.crt"} <= set(tls["data"])
    assert_tls_sans(tls, "192.0.2.50")
def assert_tls_sans(secret: dict[str, Any], service_ip: str) -> None:
    """校验生成证书的 HTTP Service DNS 和 IP SAN。

    Args: secret: TLS Secret 文档；service_ip: 可选固定服务 IP。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    certificate = x509.load_pem_x509_certificate(base64.b64decode(secret["data"]["tls.crt"]))
    names = certificate.extensions.get_extension_for_class(x509.SubjectAlternativeName).value
    dns_names = set(names.get_values_for_type(x509.DNSName))
    ip_addresses = {str(value) for value in names.get_values_for_type(x509.IPAddress)}
    fullname = "es-cluster-uino-elasticsearch"
    assert {fullname, f"{fullname}.uino.svc"} <= dns_names
    assert "127.0.0.1" in ip_addresses
    assert (service_ip in ip_addresses) is bool(service_ip)
def assert_empty_service_ip(items: list[dict[str, Any]]) -> None:
    """校验空 Service IP 不进入证书 SAN。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    tls = next(item for item in items if item["kind"] == "Secret" and "tls.crt" in item.get("data", {}))
    assert_tls_sans(tls, "")
def assert_config(items: list[dict[str, Any]]) -> None:
    """校验安全配置且静态配置不含引导节点。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    config_text = one(items, "ConfigMap")["data"]["elasticsearch.yml"]
    assert "cluster.initial_master_nodes" not in config_text
    assert "xpack.security.enabled: true" in config_text
    assert "xpack.security.transport.ssl.enabled: true" in config_text
    assert "xpack.security.http.ssl.enabled: true" in config_text
def assert_core_resources(items: list[dict[str, Any]]) -> None:
    """执行核心资源和 Pod 断言。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    service = headless_service(items)
    statefulset = one(items, "StatefulSet")
    pod = statefulset["spec"]["template"]["spec"]
    elasticsearch = named(pod["containers"], "container", "elasticsearch")
    assert_service(service)
    assert_statefulset_policy(statefulset, service["metadata"]["name"])
    assert_pod_policy(pod)
    assert_data_init(pod)
    assert_image_and_mount(elasticsearch)
    assert_security_env(elasticsearch, service["metadata"]["name"])
    assert_runtime(elasticsearch)
    assert one(items, "PodDisruptionBudget")["spec"]["minAvailable"] == 2
def assert_core(items: list[dict[str, Any]]) -> None:
    """组合执行核心集群断言。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert_resource_set(items)
    assert_core_resources(items)
    assert_secrets(items)
    assert_config(items)
def assert_existing_secrets(items: list[dict[str, Any]]) -> None:
    """校验外部 Secret 模式不生成 Secret。

    Args: items: Kubernetes 文档列表。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert not [item for item in items if item["kind"] == "Secret"]
    pod = one(items, "StatefulSet")["spec"]["template"]["spec"]
    elasticsearch = named(pod["containers"], "container", "elasticsearch")
    password_ref = env_map(elasticsearch)["ELASTIC_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert password_ref["name"] == "managed-es-credentials"
    tls_mount = named(elasticsearch["volumeMounts"], "volume mount", "tls")
    tls_volume = named(pod["volumes"], "volume", tls_mount["name"])
    assert tls_volume["secret"]["secretName"] == "managed-es-tls"
def parse_args() -> tuple[str, str]:
    """解析断言模式和渲染文件参数。

    Args: 无，读取命令行参数。
    Returns: 模式及文件路径元组。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    if len(sys.argv) != 3:
        fail("usage: assert_render.py <core|existing-secrets> <rendered.yaml>")
    return sys.argv[1], sys.argv[2]
def main() -> None:
    """校验参数并执行所选断言集。

    Args: 无，读取命令行参数。
    Returns: 断言通过时不返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    mode, path = parse_args()
    handlers: dict[str, Callable[[list[dict[str, Any]]], None]] = {
        "core": assert_core,
        "empty-service-ip": assert_empty_service_ip,
        "existing-secrets": assert_existing_secrets,
    }
    # 未知模式没有合理降级行为，必须拒绝。
    if mode not in handlers:
        fail(f"unknown mode: {mode}")
    handlers[mode](documents(path))


if __name__ == "__main__":
    main()
