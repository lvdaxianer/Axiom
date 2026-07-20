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
{{- $parts := splitList " " .Values.heap -}}
{{- $xms := index $parts 0 | trimPrefix "-Xms" | lower -}}
{{- $xmx := index $parts 1 | trimPrefix "-Xmx" | lower -}}
{{- if ne $xms $xmx -}}
{{- fail "heap Xms and Xmx must match" -}}
{{- end -}}
{{- end -}}
