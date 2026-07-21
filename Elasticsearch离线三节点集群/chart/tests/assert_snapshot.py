#!/usr/bin/env python3
# 文件说明：结构化校验 NFS 挂载、快照 Hook、SLM 请求和失败处理契约。
"""结构化校验 NFS 快照挂载、Helm Hook 和 Elasticsearch API 脚本。
通过命令行接收断言模式和渲染文件，模块本身无返回值。
Author: lvdaxianer@yeah.net
Date: 2026-07-21
"""

import sys
from typing import Any, Callable

from assert_common import documents, fail, named, one
from assert_render import EXPECTED_IMAGE, env_map

FULLNAME = "es-cluster-uino-elasticsearch"
MOUNT_PATH = "/mnt/es-snapshots"
HOOK_LABELS = {
    "app.kubernetes.io/name": "elasticsearch-client",
    "app.kubernetes.io/instance": "es-cluster",
    "app.kubernetes.io/component": "snapshot",
}
ARM64_SELECTOR = {"kubernetes.io/arch": "arm64"}
CUSTOM_PEER = {"namespaceSelector": {"matchLabels": {"kubernetes.io/metadata.name": "custom-ns"}}, "podSelector": {"matchLabels": {"app.kubernetes.io/name": "custom-client", "app.kubernetes.io/instance": "custom-release", "app.kubernetes.io/component": "custom-component"}}}  # fmt: skip
SNAPSHOT_NFS = {
    "server": "192.0.2.60",
    "path": "/exports/es-snapshots",
    "readOnly": False,
}
API_CALLS = (
    'request PUT "/_snapshot/',
    'request POST "/_snapshot/',
    'request PUT "/_slm/policy/',
)
REPOSITORY_BODY = ('"type":"fs"', '"location"', '"compress":true')
POLICY_BODY = ('"schedule"', '"repository"', '"name"', '"config"', '"retention"')
FORBIDDEN_API = ("set -x", "|| true", "request DELETE", "/_delete", "/_restore")


def pod_spec(items: list[dict[str, Any]]) -> dict[str, Any]:
    """返回 Elasticsearch StatefulSet 的 PodSpec。
    Args:
        items: Helm 渲染资源。
    Returns:
        Elasticsearch PodSpec。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    return one(items, "StatefulSet")["spec"]["template"]["spec"]


def snapshot_job(items: list[dict[str, Any]]) -> dict[str, Any]:
    """返回唯一的快照 Hook Job。
    Args:
        items: Helm 渲染资源。
    Returns:
        快照 Job 资源。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    return one(items, "Job", f"{FULLNAME}-snapshot")


def assert_config(items: list[dict[str, Any]]) -> None:
    """校验 path.repo 精确使用统一挂载路径。
    Args:
        items: Helm 渲染资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    config = one(items, "ConfigMap")["data"]["elasticsearch.yml"]
    assert f'path.repo: [ "{MOUNT_PATH}" ]' in config


def assert_nfs_mount(items: list[dict[str, Any]]) -> None:
    """校验 ES Pod 直接、可写地挂载独立 NFS export。
    Args:
        items: Helm 渲染资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    pod = pod_spec(items)
    volume = named(pod["volumes"], "snapshots")
    mount = named(
        named(pod["containers"], "elasticsearch")["volumeMounts"], "snapshots"
    )
    assert volume["nfs"] == SNAPSHOT_NFS
    assert mount["mountPath"] == MOUNT_PATH and not mount.get("readOnly", False)
    assert not [key for key in volume if key in ("persistentVolumeClaim", "hostPath")]
    assert "volumeClaimTemplates" not in one(items, "StatefulSet")["spec"]


def assert_hook_metadata(job: dict[str, Any]) -> None:
    """校验 Hook 生命周期和 NetworkPolicy 授权标签。
    Args:
        job: 快照 Job 资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    annotations = job["metadata"]["annotations"]
    assert annotations["helm.sh/hook"] == "post-install,post-upgrade"
    assert (
        annotations["helm.sh/hook-delete-policy"]
        == "before-hook-creation,hook-succeeded"
    )
    assert job["metadata"]["namespace"] == "uino"
    labels = job["spec"]["template"]["metadata"]["labels"]
    assert HOOK_LABELS.items() <= labels.items()


def assert_job_policy(job: dict[str, Any]) -> dict[str, Any]:
    """校验 Job 执行边界并返回快照容器。
    Args:
        job: 快照 Job 资源。
    Returns:
        快照容器定义。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    spec = job["spec"]
    pod = spec["template"]["spec"]
    assert spec["backoffLimit"] <= 3 and 60 <= spec["activeDeadlineSeconds"] <= 900
    assert pod["restartPolicy"] == "Never" and pod["securityContext"]["runAsNonRoot"] is True  # fmt: skip
    assert pod["nodeSelector"] == ARM64_SELECTOR and pod["imagePullSecrets"] == [{"name": "registry-credentials"}]  # fmt: skip
    container = named(pod["containers"], "snapshot-register")
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    return container


def assert_identity(
    job: dict[str, Any], container: dict[str, Any], credential: str, tls: str
) -> None:
    """校验 Job 复用期望镜像、凭据 Secret 和 CA Secret。
    Args:
        job: 快照 Job；container: 快照容器；credential: 密码 Secret；tls: TLS Secret。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert container["image"] == EXPECTED_IMAGE
    password = env_map(container)["ELASTIC_PASSWORD"]["valueFrom"]["secretKeyRef"]
    assert password == {"name": credential, "key": "elastic-password"}
    ca_mount = named(container["volumeMounts"], "tls-ca")
    assert ca_mount["readOnly"] is True and ca_mount["mountPath"] == "/etc/elasticsearch/tls"  # fmt: skip
    volume = named(job["spec"]["template"]["spec"]["volumes"], "tls-ca")
    assert volume["secret"]["secretName"] == tls
    assert volume["secret"]["items"] == [{"key": "ca.crt", "path": "ca.crt"}]


def assert_api_script(container: dict[str, Any]) -> None:
    """校验 API 顺序、请求体、失败传播和重试上界。
    Args:
        container: 快照容器定义。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    script = "\n".join(container["args"])
    assert all(call in script for call in API_CALLS)
    assert all(token in script for token in REPOSITORY_BODY)
    assert all(token in script for token in POLICY_BODY)
    assert '"indices":["*"]' in script and '"include_global_state":true' in script
    assert "set -euo pipefail" in script and "--fail" in script and "exit 1" in script
    assert "--retry 2" in script and "--max-time 15" in script
    assert not any(token in script for token in FORBIDDEN_API)


def assert_env_contract(container: dict[str, Any]) -> None:
    """校验仓库位置和 SLM 策略输入的规范值。
    Args:
        container: 快照容器定义。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    env = env_map(container)
    expected = {"REPOSITORY_NAME": "uino-es-snapshot", "SNAPSHOT_LOCATION": f"{MOUNT_PATH}/uino/es-cluster", "SLM_ENABLED": "true", "SLM_POLICY_NAME": "uino-es-daily", "SLM_SCHEDULE": "0 30 1 * * ?", "SLM_SNAPSHOT_NAME": "<uino-es-snapshot-{now/d}>", "SLM_EXPIRE_AFTER": "30d", "SLM_MIN_COUNT": "5", "SLM_MAX_COUNT": "50"}  # fmt: skip
    assert all(env[name]["value"] == value for name, value in expected.items())


def http_sources(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """返回 NetworkPolicy 中 Elasticsearch HTTP 的全部来源。
    Args:
        items: Helm 渲染资源。
    Returns:
        HTTP ingress 来源列表。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    policy = one(items, "NetworkPolicy", FULLNAME)
    rule = next(
        rule for rule in policy["spec"]["ingress"] if rule["ports"][0]["port"] == 9200
    )
    return rule["from"]


def assert_network_peer(items: list[dict[str, Any]], job: dict[str, Any]) -> None:
    """校验默认 NetworkPolicy peer 精确授权快照 Job。
    Args:
        items: Helm 渲染资源；job: 快照 Job。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    peer = next(source for source in http_sources(items) if "podSelector" in source)
    namespace = peer["namespaceSelector"]["matchLabels"]
    labels = job["spec"]["template"]["metadata"]["labels"]
    assert namespace == {"kubernetes.io/metadata.name": "uino"}
    assert peer["podSelector"]["matchLabels"] == HOOK_LABELS
    assert HOOK_LABELS.items() <= labels.items()


def assert_custom_peer(items: list[dict[str, Any]], job: dict[str, Any]) -> None:
    """校验自定义 peer 不会取代固定快照 Hook 授权。
    Args:
        items: Helm 渲染资源；job: 快照 Job。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert_network_peer(items, job)
    assert CUSTOM_PEER in http_sources(items)


def assert_service_mismatch(items: list[dict[str, Any]], job: dict[str, Any]) -> None:
    """确认授权 Job 标签不会匹配 Elasticsearch Service selector。
    Args:
        items: Helm 渲染资源；job: 快照 Job。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    labels = job["spec"]["template"]["metadata"]["labels"]
    selector = one(items, "Service", FULLNAME)["spec"]["selector"]
    assert HOOK_LABELS.items() <= labels.items()
    assert not selector.items() <= labels.items()


def assert_enabled(items: list[dict[str, Any]]) -> None:
    """组合执行默认快照契约断言。
    Args:
        items: Helm 渲染资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    assert_config(items)
    assert_nfs_mount(items)
    job = snapshot_job(items)
    assert_hook_metadata(job)
    container = assert_job_policy(job)
    assert_identity(job, container, f"{FULLNAME}-credentials", f"{FULLNAME}-tls")
    assert_service_mismatch(items, job)
    assert_network_peer(items, job)
    assert_env_contract(container)
    assert_api_script(container)


def assert_external(items: list[dict[str, Any]]) -> None:
    """校验快照 Job 引用外部身份材料。
    Args:
        items: Helm 渲染资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    job = snapshot_job(items)
    container = assert_job_policy(job)
    assert_identity(job, container, "managed-es-credentials", "managed-es-tls")


def assert_disabled(items: list[dict[str, Any]]) -> None:
    """校验关闭快照时完全省略运行资源。
    Args:
        items: Helm 渲染资源。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    config = one(items, "ConfigMap")["data"]["elasticsearch.yml"]
    pod = pod_spec(items)
    assert "path.repo" not in config and not [
        item for item in items if item["kind"] == "Job"
    ]
    assert not [item for item in pod["volumes"] if item["name"] == "snapshots"]
    mounts = named(pod["containers"], "elasticsearch")["volumeMounts"]
    assert not [item for item in mounts if item["name"] == "snapshots"]
    peers = [source for source in http_sources(items) if "podSelector" in source]
    assert not any(
        peer["podSelector"]["matchLabels"] == HOOK_LABELS for peer in peers
    )


def parse_args() -> tuple[str, str]:
    """解析快照断言模式和渲染路径。
    Args:
        无，读取命令行参数。
    Returns:
        模式和文件路径。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    # 参数数量错误时拒绝猜测测试模式。
    if len(sys.argv) != 3:
        fail("usage: assert_snapshot.py <mode> <rendered.yaml>")
    return sys.argv[1], sys.argv[2]


def main() -> None:
    """选择并执行快照结构化断言。
    Args:
        无，读取命令行参数。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    mode, path = parse_args()
    handlers: dict[str, Callable[[list[dict[str, Any]]], None]] = {
        "enabled": assert_enabled,
        "external": assert_external,
        "disabled": assert_disabled,
        "custom-peer": lambda items: assert_custom_peer(items, snapshot_job(items)),
    }
    # 未知模式必须显式失败，避免遗漏断言。
    if mode not in handlers:
        fail(f"unknown mode: {mode}")
    handlers[mode](documents(path))


# 仅直接运行时执行，供其他断言复用时保持无副作用。
if __name__ == "__main__":
    main()
