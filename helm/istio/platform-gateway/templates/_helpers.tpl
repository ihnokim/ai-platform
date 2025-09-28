{{/*
Expand the name of the chart.
*/}}
{{- define "platform-gateway.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "platform-gateway.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "platform-gateway.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "platform-gateway.labels" -}}
{{ include "platform-gateway.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "platform-gateway.selectorLabels" -}}
app.kubernetes.io/name: {{ include "platform-gateway.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Define platform-gateway.servers depending on tls.enabled
*/}}
{{- define "platform-gateway.servers"}}
{{ if not .Values.tls.enabled }}
  - hosts:
    - {{ .Values.host }}
    - "*.{{ .Values.host }}"
    port:
      name: http
      number: 80
      protocol: HTTP
{{ else }}
  - hosts:
    - {{ .Values.host }}
    - "*.{{ .Values.host }}"
    port:
      name: http
      number: 80
      protocol: HTTP2
    tls:
      httpsRedirect: true
  - hosts:
    - {{ .Values.host }}
    - "*.{{ .Values.host }}"
    port:
      name: https
      number: 443
      protocol: HTTPS
    tls:
      credentialName: {{ .Values.tls.credentialName }}
      mode: SIMPLE
{{ end }}
{{- end}}
