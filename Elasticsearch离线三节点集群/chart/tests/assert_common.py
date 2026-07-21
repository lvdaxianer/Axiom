#!/usr/bin/env python3
# 文件说明：提供渲染清单解析、资源筛选和统一失败处理等测试公共工具。
"""提供 Helm 结构化测试共享的 YAML 和资源查找工具。

Args:
    无，提供可导入的共享函数。
Returns:
    模块本身无返回值。
Author: lvdaxianer@yeah.net
Date: 2026-07-21
"""

from typing import Any

import yaml


def fail(message: str) -> None:
    """抛出带上下文的结构化断言错误。
    Args:
        message: 失败原因。
    Returns:
        无返回值，始终抛出异常。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    raise AssertionError(message)


def documents(path: str) -> list[dict[str, Any]]:
    """读取 Helm 输出中的非空 YAML 文档。
    Args:
        path: Helm 渲染文件路径。
    Returns:
        Kubernetes 资源列表。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    with open(path, encoding="utf-8") as stream:
        return [document for document in yaml.safe_load_all(stream) if document]


def one(items: list[dict[str, Any]], kind: str, name: str = "") -> dict[str, Any]:
    """按类型和可选名称查找唯一资源。
    Args:
        items: 资源列表；kind: 资源类型；name: 可选资源名称。
    Returns:
        唯一匹配的资源。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    matches = [item for item in items if item.get("kind") == kind]
    matches = [item for item in matches if not name or item["metadata"]["name"] == name]
    # 资源缺失或重复时必须报告实际数量，避免测试静默选错对象。
    if len(matches) != 1:
        fail(f"expected one {kind} {name}, found {len(matches)}")
    return matches[0]


def named(items: list[dict[str, Any]], name: str) -> dict[str, Any]:
    """按 name 字段查找唯一子资源。
    Args:
        items: 子资源列表；name: 目标名称。
    Returns:
        唯一匹配的子资源。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    matches = [item for item in items if item["name"] == name]
    # 子资源缺失或重复时必须失败，保持结构化断言的唯一性。
    if len(matches) != 1:
        fail(f"expected one named item {name}, found {len(matches)}")
    return matches[0]
