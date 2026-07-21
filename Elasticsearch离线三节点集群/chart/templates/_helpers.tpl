{{- /* 文件说明：集中定义资源命名、标准标签、Secret 引用、镜像身份和 JVM 堆校验助手。 */ -}}
{{- define "uino-elasticsearch.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "uino-elasticsearch.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "uino-elasticsearch.name" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "uino-elasticsearch.labels" -}}
app.kubernetes.io/name: {{ include "uino-elasticsearch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "uino-elasticsearch.selectorLabels" -}}
app.kubernetes.io/name: {{ include "uino-elasticsearch.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "uino-elasticsearch.headlessServiceName" -}}
{{- printf "%s-headless" (include "uino-elasticsearch.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "uino-elasticsearch.credentialsSecretName" -}}
{{- /* 优先引用客户预置 Secret，留空时才使用 Chart 管理的稳定名称。 */ -}}
{{- if .Values.security.existingCredentialsSecret -}}
{{- .Values.security.existingCredentialsSecret -}}
{{- else -}}
{{- printf "%s-credentials" (include "uino-elasticsearch.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uino-elasticsearch.tlsSecretName" -}}
{{- if .Values.tls.existingSecret -}}
{{- .Values.tls.existingSecret -}}
{{- else -}}
{{- printf "%s-tls" (include "uino-elasticsearch.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "uino-elasticsearch.image" -}}
{{- printf "%s:%s@%s" .Values.image.repository .Values.image.tag .Values.image.digest -}}
{{- end -}}

{{- define "uino-elasticsearch.validateHeap" -}}
{{- /* 固定 Xms=Xmx，避免 Elasticsearch 在容器内动态调整堆造成不可预测的内存压力。 */ -}}
{{- $parts := splitList " " .Values.heap -}}
{{- $xms := index $parts 0 | trimPrefix "-Xms" | lower -}}
{{- $xmx := index $parts 1 | trimPrefix "-Xmx" | lower -}}
{{- if ne $xms $xmx -}}
{{- fail "heap Xms and Xmx must match" -}}
{{- end -}}
{{- end -}}
