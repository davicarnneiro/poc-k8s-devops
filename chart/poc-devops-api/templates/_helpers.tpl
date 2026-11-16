{{- define "poc-devops-api.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "poc-devops-api.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "poc-devops-api.labels" -}}
app.kubernetes.io/name: {{ include "poc-devops-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "poc-devops-api.selectorLabels" -}}
app.kubernetes.io/name: {{ include "poc-devops-api.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}