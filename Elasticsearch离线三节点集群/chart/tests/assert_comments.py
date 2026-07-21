#!/usr/bin/env python3
# 文件说明：校验 JSON Schema 使用合法中文 description 承载文件和配置组说明。
"""为注释覆盖测试提供严格 JSON 解析和中文 description 断言。

Args:
    无，通过命令行接收 values.schema.json 路径。
Returns:
    模块本身无返回值。
Author: lvdaxianer@yeah.net
Date: 2026-07-21
"""

import json
import sys

CJK_FIRST_CHARACTER = "\u4e00"
CJK_LAST_CHARACTER = "\u9fff"
EXPECTED_ARGUMENT_COUNT = 2
SCHEMA_PATH_ARGUMENT_INDEX = 1


def has_chinese(value: object) -> bool:
    """判断 Schema description 是否包含中文职责说明。
    Args:
        value: 待检查的任意 JSON 值。
    Returns:
        字符串含中文字符时返回 True，否则返回 False。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    return isinstance(value, str) and any(
        CJK_FIRST_CHARACTER <= character <= CJK_LAST_CHARACTER for character in value
    )


def validate_schema(path: str) -> None:
    """校验 Schema 顶层和全部一级配置组的中文说明。
    Args:
        path: values.schema.json 文件路径。
    Returns:
        无返回值，缺少说明时抛出 AssertionError。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    # 标准库解析会拒绝 JSON 不支持的 # 或 // 注释。
    with open(path, encoding="utf-8") as schema_file:
        schema = json.load(schema_file)
    assert has_chinese(schema.get("description")), "顶层缺少中文 description"
    # 动态遍历 properties，未来新增的一级配置组也会自动进入审计。
    for name, definition in schema["properties"].items():
        assert has_chinese(definition.get("description")), f"{name} 缺少中文 description"


def main() -> None:
    """解析命令行参数并执行 Schema 注释审计。
    Args:
        无，读取命令行参数。
    Returns:
        无返回值。
    Author: lvdaxianer@yeah.net
    Date: 2026-07-21
    """
    # 参数数量不正确时拒绝猜测待审计文件。
    if len(sys.argv) != EXPECTED_ARGUMENT_COUNT:
        raise SystemExit("usage: assert_comments.py <values.schema.json>")
    validate_schema(sys.argv[SCHEMA_PATH_ARGUMENT_INDEX])


# 仅直接运行时执行断言，导入函数进行单独检查时保持无副作用。
if __name__ == "__main__":
    main()
