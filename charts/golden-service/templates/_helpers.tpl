{{/*
Helpers for the golden-service chart. Names derive from the release so a
single chart serves ~100 services distinguished only by values (R4).
*/}}

{{/* Chart name, sanitized for use as a Kubernetes name segment. */}}
{{- define "golden-service.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified resource name: <release>-<chart>, DNS-safe. */}}
{{- define "golden-service.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels — stable across upgrades, so never include volatile data. */}}
{{- define "golden-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "golden-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Platform-required labels (conventions.md). GPU-admission policy denies pods
missing team + class; customer-data guards node tenancy. Never a Kueue label:
serving is never queue-admitted (KTD6).
*/}}
{{- define "golden-service.platformLabels" -}}
team.synorg.io/name: {{ .Values.team | quote }}
workload.synorg.io/class: {{ .Values.workloadClass | quote }}
{{- if .Values.customerData }}
data.synorg.io/customer-data: "true"
{{- end }}
{{- end -}}

{{/* Full label set applied to every rendered object. */}}
{{- define "golden-service.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{ include "golden-service.selectorLabels" . }}
{{ include "golden-service.platformLabels" . }}
{{- end -}}

{{/* ServiceAccount name: created SA defaults to fullname, else "default". */}}
{{- define "golden-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "golden-service.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}
