{{- /* 文件说明：集中定义资源命名、标准标签、Secret 引用、镜像身份和 JVM 堆校验助手。 */ -}}
{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.name" -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.fullname" -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- printf "%s-%s" .Release.Name (include "uino-elasticsearch.name" .) | trunc 63 | trimSuffix "-" -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.labels" -}}
app.kubernetes.io/name: {{ include "uino-elasticsearch.name" . }}{{/* 行说明：配置 app.kubernetes.io/name 字段，形成 _helpers.tpl 所需资源。 */}}
app.kubernetes.io/instance: {{ .Release.Name }}{{/* 行说明：配置 app.kubernetes.io/instance 字段，形成 _helpers.tpl 所需资源。 */}}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}{{/* 行说明：配置 app.kubernetes.io/version 字段，形成 _helpers.tpl 所需资源。 */}}
app.kubernetes.io/managed-by: {{ .Release.Service }}{{/* 行说明：配置 app.kubernetes.io/managed-by 字段，形成 _helpers.tpl 所需资源。 */}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}{{/* 行说明：配置 helm.sh/chart 字段，形成 _helpers.tpl 所需资源。 */}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.selectorLabels" -}}
app.kubernetes.io/name: {{ include "uino-elasticsearch.name" . }}{{/* 行说明：配置 app.kubernetes.io/name 字段，形成 _helpers.tpl 所需资源。 */}}
app.kubernetes.io/instance: {{ .Release.Name }}{{/* 行说明：配置 app.kubernetes.io/instance 字段，形成 _helpers.tpl 所需资源。 */}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.headlessServiceName" -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- printf "%s-headless" (include "uino-elasticsearch.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.credentialsSecretName" -}}
{{- /* 优先引用客户预置 Secret，留空时才使用 Chart 管理的稳定名称。 */ -}}
{{- /* 行说明：仅在该 Helm 条件成立时渲染后续内容。 */}}{{- if .Values.security.existingCredentialsSecret -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- .Values.security.existingCredentialsSecret -}}
{{- /* 行说明：条件不成立时切换到备用渲染分支。 */}}{{- else -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- printf "%s-credentials" (include "uino-elasticsearch.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.tlsSecretName" -}}
{{- /* 行说明：仅在该 Helm 条件成立时渲染后续内容。 */}}{{- if .Values.tls.existingSecret -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- .Values.tls.existingSecret -}}
{{- /* 行说明：条件不成立时切换到备用渲染分支。 */}}{{- else -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- printf "%s-tls" (include "uino-elasticsearch.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.image" -}}
{{- /* 行说明：执行 Helm 模板表达式并将结果写入当前位置。 */}}{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}

{{- /* 行说明：定义可被其他模板复用的 Helm helper。 */}}{{- define "uino-elasticsearch.validateHeap" -}}
{{- /* 固定 Xms=Xmx，避免 Elasticsearch 在容器内动态调整堆造成不可预测的内存压力。 */ -}}
{{- /* 行说明：计算并保存后续模板渲染需要的局部变量。 */}}{{- $parts := splitList " " .Values.heap -}}
{{- /* 行说明：计算并保存后续模板渲染需要的局部变量。 */}}{{- $xms := index $parts 0 | trimPrefix "-Xms" | lower -}}
{{- /* 行说明：计算并保存后续模板渲染需要的局部变量。 */}}{{- $xmx := index $parts 1 | trimPrefix "-Xmx" | lower -}}
{{- /* 行说明：仅在该 Helm 条件成立时渲染后续内容。 */}}{{- if ne $xms $xmx -}}
{{- /* 行说明：配置违反安全约束时立即终止 Helm 渲染。 */}}{{- fail "heap Xms and Xmx must match" -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}
{{- /* 行说明：结束当前 Helm 定义、条件或遍历块。 */}}{{- end -}}
