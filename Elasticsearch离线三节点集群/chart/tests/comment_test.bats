#!/usr/bin/env bats
# 文件说明：审计 Chart 全部源文件的中文职责说明，并验证 JSON Schema 注释方式合法。
# 审计对象只包含人工维护的 YAML、Helm、Python 和 Bats 源文件。
# JSON 不能使用行注释，因此由标准 description 字段承载等价说明。
# 统一“文件说明：”标记让交付前审计无需推测不同语言的注释风格。
# 本测试只约束职责说明是否存在，说明是否准确仍由代码审查负责。
# 复杂逻辑的就近注释由完整 diff 审查确认，不用脆弱的关键字数量替代。
# fixture 也属于客户交付维护面，因此与模板和测试脚本使用同一规则。

PURPOSE_HEADER_LINES=12

# 初始化 Chart 根目录，保证测试不依赖调用命令时的当前工作目录。
# Args: 无，使用 Bats 注入的测试目录。
# Returns: 设置供后续测试使用的 CHART_DIR 和 ASSERT_COMMENTS。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-21
setup() {
  CHART_DIR="$(cd "${BATS_TEST_DIRNAME}/.." && pwd)"
  ASSERT_COMMENTS="${BATS_TEST_DIRNAME}/assert_comments.py"
  LINE_COMMENT_FILES=(
    "$CHART_DIR/Chart.yaml"
    "$CHART_DIR/values.yaml"
    "$CHART_DIR/values.customer.example.yaml"
    "$CHART_DIR/values.x86.yaml"
    "$CHART_DIR/tests/fixtures/valid-values.yaml"
    "$CHART_DIR/templates/"*
  )
}

# 输出缺少统一职责标记的相对文件路径。
# Args: 无，读取 setup 初始化的 CHART_DIR。
# Returns: 每行一个缺少说明的相对路径；全部合格时无输出。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-21
find_missing_purpose_comments() {
  # 固定后缀范围，避免把缓存、压缩包或其他生成物误判为源文件。
  # sort 固定失败输出顺序，使本地和客户环境得到一致诊断。
  # Helm 模板使用不会进入资源的模板注释，仍可被源文件扫描识别。
  # YAML、Python 和 Bats 使用各自原生行注释，不引入额外解析依赖。
  find "$CHART_DIR" -type f \
    \( -name '*.yaml' -o -name '*.tpl' -o -name '*.py' -o -name '*.bats' \) \
    | sort \
    | while IFS= read -r file; do
        # 文件前 12 行必须明确给出统一的中文职责标记。
        if ! head -n "$PURPOSE_HEADER_LINES" "$file" | grep -q "文件说明："; then
          # 流式输出缺失项，避免在循环内反复拼接不可变字符串。
          # 标准输出只承载相对路径，调用方统一负责呈现错误前缀。
          printf '%s\n' "${file#"${CHART_DIR}/"}"
        fi
      done
}

# 输出缺少独立前置行说明的 Helm 模板位置。
# Args: $1 为待审计模板文件。
# Returns: 每行一个“相对路径:行号”；全部合格时无输出。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-27
find_missing_template_line_comments() {
  awk -v prefix="${1#"${CHART_DIR}/"}" '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\{\{[-]?[[:space:]]*\/\*/ {
      has_explanation = index($0, "行说明：") > 0
      next
    }
    !has_explanation { print prefix ":" NR }
    { has_explanation = 0 }
  ' "$1"
}

# 输出缺少同行 # 行说明的普通 YAML 位置。
# Args: $1 为待审计 YAML 文件。
# Returns: 每行一个“相对路径:行号”；全部合格时无输出。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-27
find_missing_yaml_line_comments() {
  awk -v prefix="${1#"${CHART_DIR}/"}" '
    /^[[:space:]]*$/ { next }
    /^[[:space:]]*#/ { next }
    index($0, "# 行说明：") == 0 { print prefix ":" NR }
  ' "$1"
}

# 输出缺少逐行中文说明的部署源码位置。
# Args: 无，读取 setup 初始化的 LINE_COMMENT_FILES。
# Returns: 每行一个“相对路径:行号”；全部合格时无输出。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-21
find_missing_line_comments() {
  local file
  for file in "${LINE_COMMENT_FILES[@]}"; do
    # Helm 模板与普通 YAML 使用各自合法且易读的注释格式。
    if [[ "$file" == *"/templates/"* ]]; then
      find_missing_template_line_comments "$file"
    else
      find_missing_yaml_line_comments "$file"
    fi
  done
}

# 输出仍与有效内容共用一行的 Helm 行说明位置。
# Args: 无，读取 setup 初始化的 CHART_DIR。
# Returns: 每行一个“相对路径:行号”；全部为独立注释行时无输出。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-27
find_embedded_template_comments() {
  find "$CHART_DIR/templates" -type f \( -name '*.yaml' -o -name '*.tpl' \) \
    | sort \
    | while IFS= read -r file; do
        awk -v prefix="${file#"${CHART_DIR}/"}" '
          /行说明：/ && $0 !~ /^[[:space:]]*\{\{[-]?[[:space:]]*\/\*.*\*\/[[:space:]]*[-]?\}\}[[:space:]]*$/ {
            print prefix ":" NR
          }
        ' "$file"
      done
}

# 验证所有非 JSON 源文件的头部职责说明。
# Args: 无，使用 setup 初始化的 Chart 路径。
# Returns: 全部文件有职责标记时通过，否则输出缺失路径。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-21
@test "every non-JSON source file has a Chinese purpose comment" {
  # 一次性收集流式结果，空字符串表示覆盖完整。
  missing="$(find_missing_purpose_comments)"

  # 仅缺失时打印全部相对路径，正常路径保持测试输出简洁。
  [ -z "$missing" ] || {
    printf '以下文件缺少中文文件说明：\n%s' "$missing"
    return 1
  }
}

# 验证部署 YAML 和 Helm 模板的每个有效源码行都有中文说明。
# Args: 无，使用 setup 初始化的部署文件集合。
# Returns: 全部有效行有说明时通过，否则输出缺失位置。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-21
@test "every deployment source line has a Chinese explanation" {
  missing="$(find_missing_line_comments)"
  [ -z "$missing" ] || {
    printf '以下源码行缺少逐行中文说明：\n%s\n' "$missing"
    return 1
  }
}

# 验证 Helm 行说明使用独立注释行，不与有效 YAML 或模板表达式混排。
# Args: 无，使用 setup 初始化的模板目录。
# Returns: 所有行说明均独立成行时通过，否则输出嵌入位置。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-27
@test "Helm line comments are standalone source lines" {
  embedded="$(find_embedded_template_comments)"
  [ -z "$embedded" ] || {
    printf '以下 Helm 行说明与有效内容嵌入在同一行：\n%s\n' "$embedded"
    return 1
  }
}

# 验证 Schema 使用合法 JSON 注释机制，并覆盖每个顶层配置组。
# Args: 无，使用 setup 初始化的 Python 断言脚本。
# Returns: Schema 合法且中文说明完整时通过，否则透传断言错误。
# Author: lvdaxianer@yeah.net
# Date: 2026-07-21
@test "JSON Schema uses Chinese descriptions and remains valid JSON" {
  # Python 标准库会拒绝非法 JSON 注释，断言脚本再检查中文 description。
  run python3 "$ASSERT_COMMENTS" "$CHART_DIR/values.schema.json"

  # Python 失败时透传具体配置组，便于直接定位缺失说明。
  [ "$status" -eq 0 ] || {
    printf '%s\n' "$output"
    return 1
  }
}
