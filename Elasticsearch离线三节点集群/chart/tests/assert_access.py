#!/usr/bin/env python3
# 文件说明：结构化校验 MetalLB 固定 IP、TLS SAN 和 NetworkPolicy 访问边界。
"""结构化校验 Elasticsearch 固定 IP 服务和双向网络隔离策略。

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

from assert_common import documents, fail, one

SERVICE_NAME = "es-cluster-uino-elasticsearch"
SERVICE_IP = "192.0.2.50"
SOURCE_CIDR = "198.51.100.0/24"
ES_SELECTOR = {
    "app.kubernetes.io/name": "uino-elasticsearch",
    "app.kubernetes.io/instance": "es-cluster",
}
HOOK_SELECTOR = {
    "app.kubernetes.io/name": "elasticsearch-client",
    "app.kubernetes.io/instance": "es-cluster",
    "app.kubernetes.io/component": "snapshot",
}
DNS_NAMESPACE_SELECTOR = {"kubernetes.io/metadata.name": "kube-system"}
DNS_POD_SELECTOR = {"k8s-app": "kube-dns"}


def tls_secret(items: list[dict[str, Any]]) -> dict[str, Any]:
    """查找 Chart 生成的 TLS Secret。
    Args:
        items: 资源列表。
    Returns:
        包含 tls.crt 的 Secret。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    matches = [
        item
        for item in items
        if item.get("kind") == "Secret" and "tls.crt" in item.get("data", {})
    ]
    # TLS Secret 缺失或重复时必须失败，避免解析错误的证书对象。
    if len(matches) != 1:
        fail(f"expected one TLS Secret, found {len(matches)}")
    return matches[0]


def assert_tls_sans(secret: dict[str, Any]) -> None:
    """校验证书包含固定 IP 和 HTTP Service DNS。
    Args:
        secret: TLS Secret 资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    certificate = x509.load_pem_x509_certificate(
        base64.b64decode(secret["data"]["tls.crt"])
    )
    names = certificate.extensions.get_extension_for_class(
        x509.SubjectAlternativeName
    ).value
    dns_names = set(names.get_values_for_type(x509.DNSName))
    ip_addresses = {str(value) for value in names.get_values_for_type(x509.IPAddress)}
    assert {SERVICE_NAME, f"{SERVICE_NAME}.uino.svc"} <= dns_names
    assert {"127.0.0.1", SERVICE_IP} <= ip_addresses


def assert_annotations(annotations: dict[str, str]) -> None:
    """校验固定 MetalLB 注解和合法自定义注解。
    Args:
        annotations: Service 注解映射。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert annotations["example.com/owner"] == "platform"
    assert annotations["metallb.universe.tf/address-pool"] == "first-pool"
    assert annotations["metallb.universe.tf/loadBalancerIPs"] == SERVICE_IP
    assert annotations["metallb.universe.tf/protocol"] == "layer2"


def assert_http_service(items: list[dict[str, Any]]) -> dict[str, Any]:
    """校验固定 IP Service 仅以 Local 模式暴露 HTTPS 9200。
    Args:
        items: 资源列表。
    Returns:
        已验证的 HTTP Service。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    service = one(items, "Service", SERVICE_NAME)
    spec = service["spec"]
    assert spec["type"] == "LoadBalancer" and spec["loadBalancerIP"] == SERVICE_IP
    assert spec["externalTrafficPolicy"] == "Local"
    assert spec["loadBalancerSourceRanges"] == [SOURCE_CIDR] and spec["selector"] == ES_SELECTOR  # fmt: skip
    assert spec["ports"] == [{"name": "http", "protocol": "TCP", "port": 9200, "targetPort": "http"}]  # fmt: skip
    assert_annotations(service["metadata"]["annotations"])
    return service


def rule_for_port(rules: list[dict[str, Any]], port: int) -> dict[str, Any]:
    """按唯一端口查找 NetworkPolicy 规则。
    Args:
        rules: ingress 或 egress 规则；port: 目标端口。
    Returns:
        唯一匹配的规则。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    matches = [
        rule for rule in rules if any(item["port"] == port for item in rule["ports"])
    ]
    # 目标端口规则缺失或重复时必须失败，防止宽泛规则被忽略。
    if len(matches) != 1:
        fail(f"expected one rule for port {port}, found {len(matches)}")
    return matches[0]


def assert_ingress(rules: list[dict[str, Any]]) -> None:
    """校验 transport 和 HTTP 入站来源边界。
    Args:
        rules: NetworkPolicy ingress 规则。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert len(rules) == 2
    transport = rule_for_port(rules, 9300)
    assert transport == {"from": [{"podSelector": {"matchLabels": ES_SELECTOR}}], "ports": [{"protocol": "TCP", "port": 9300}]}  # fmt: skip
    http_sources = rule_for_port(rules, 9200)["from"]
    assert {source["ipBlock"]["cidr"] for source in http_sources if "ipBlock" in source} == {SOURCE_CIDR}  # fmt: skip
    peers = [source for source in http_sources if "ipBlock" not in source]
    expected = {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "uino"}}, "podSelector": {"matchLabels": HOOK_SELECTOR}}  # fmt: skip
    assert peers == [expected]


def assert_egress(rules: list[dict[str, Any]]) -> None:
    """校验出站仅允许 ES transport 和集群 DNS。
    Args:
        rules: NetworkPolicy egress 规则。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert len(rules) == 2
    transport = rule_for_port(rules, 9300)
    assert transport == {"to": [{"podSelector": {"matchLabels": ES_SELECTOR}}], "ports": [{"protocol": "TCP", "port": 9300}]}  # fmt: skip
    dns = rule_for_port(rules, 53)
    expected_peer = {"namespaceSelector": {"matchLabels": DNS_NAMESPACE_SELECTOR}, "podSelector": {"matchLabels": DNS_POD_SELECTOR}}  # fmt: skip
    assert dns["to"] == [expected_peer]
    assert dns["ports"] == [{"protocol": "UDP", "port": 53}, {"protocol": "TCP", "port": 53}]  # fmt: skip


def assert_network_policy(items: list[dict[str, Any]], service: dict[str, Any]) -> None:
    """校验 NetworkPolicy 对 ES Pod 启用双向隔离。
    Args:
        items: 资源列表；service: 已验证的 HTTP Service。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    policy = one(items, "NetworkPolicy", SERVICE_NAME)
    spec = policy["spec"]
    assert spec["podSelector"]["matchLabels"] == service["spec"]["selector"]
    assert spec["policyTypes"] == ["Ingress", "Egress"]
    assert_ingress(spec["ingress"])
    assert_egress(spec["egress"])


def assert_secure(items: list[dict[str, Any]]) -> None:
    """组合执行 Service、TLS 和双向网络策略断言。
    Args:
        items: 资源列表。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    service = assert_http_service(items)
    assert_network_policy(items, service)
    assert_tls_sans(tls_secret(items))


def assert_no_sharing(items: list[dict[str, Any]]) -> None:
    """确认默认不渲染共享 IP 注解。
    Args:
        items: 资源列表。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    annotations = one(items, "Service", SERVICE_NAME)["metadata"]["annotations"]
    assert "metallb.universe.tf/allow-shared-ip" not in annotations


def assert_shared(items: list[dict[str, Any]]) -> None:
    """确认启用共享 IP 时使用显式安全键。
    Args:
        items: 资源列表。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    annotations = one(items, "Service", SERVICE_NAME)["metadata"]["annotations"]
    assert annotations["metallb.universe.tf/allow-shared-ip"] == "es-http-shared"
    assert_annotations(annotations)


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
        fail("usage: assert_access.py <mode> <rendered.yaml>")
    return sys.argv[1], sys.argv[2]


def main() -> None:
    """选择并执行安全访问断言集。
    Args:
        无，读取命令行参数。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    mode, path = parse_args()
    handlers: dict[str, Callable[[list[dict[str, Any]]], None]] = {
        "secure": assert_secure,
        "no-sharing": assert_no_sharing,
        "shared": assert_shared,
    }
    # 未注册模式不能静默降级到其他安全断言集。
    if mode not in handlers:
        fail(f"unknown mode: {mode}")
    handlers[mode](documents(path))


# 仅直接执行脚本时启动命令行断言，导入共享函数时保持无副作用。
if __name__ == "__main__":
    main()
