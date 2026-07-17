{{/*
Helpers for the training-job chart. Mirrors golden-service so services and
training share one values+schema shape (R4 symmetry); the difference is the
workload class is fixed to "training" and the object is a Kueue-admitted Job.
*/}}

{{/* Chart name, sanitized for use as a Kubernetes name segment. */}}
{{- define "training-job.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified resource name: <release>-<chart>, DNS-safe. */}}
{{- define "training-job.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Selector labels — stable across upgrades, so never include volatile data. */}}
{{- define "training-job.selectorLabels" -}}
app.kubernetes.io/name: {{ include "training-job.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Platform-required labels (conventions.md). GPU-admission policy denies pods
missing team + class. workload.synorg.io/class is fixed to "training": this
chart never renders anything else, which is exactly why serving uses a different
chart and this one carries the Kueue queue label instead (KTD6).
*/}}
{{- define "training-job.platformLabels" -}}
team.synorg.io/name: {{ .Values.team | quote }}
workload.synorg.io/class: training
{{- end -}}

{{/* Full label set applied to every rendered object. */}}
{{- define "training-job.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.tag | quote }}
{{ include "training-job.selectorLabels" . }}
{{ include "training-job.platformLabels" . }}
{{- end -}}
