{{- define "crowdsec-waf.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "crowdsec-waf.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name (include "crowdsec-waf.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "crowdsec-waf.proxyName" -}}
{{- printf "%s-proxy" (include "crowdsec-waf.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "crowdsec-waf.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "crowdsec-waf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "crowdsec-waf.proxySelectorLabels" -}}
app.kubernetes.io/name: {{ include "crowdsec-waf.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/component: waf-proxy
{{- end }}

{{/* Detect mode never blocks. */}}
{{- define "crowdsec-waf.isBlock" -}}
{{- if eq .Values.waf.mode "block" }}true{{ end -}}
{{- end }}

{{/* Access log format: common is forced when the CrowdSec agent parses the logs. */}}
{{- define "crowdsec-waf.accessLogFormat" -}}
{{- if and .Values.crowdsec.agent .Values.crowdsec.agent.enabled }}common{{ else }}{{ .Values.proxy.accessLog.format }}{{ end -}}
{{- end }}

{{/* Services created by the official crowdsec chart are named after the release. */}}
{{- define "crowdsec-waf.lapiHost" -}}
{{ .Release.Name }}-service.{{ .Release.Namespace }}:8080
{{- end }}
{{- define "crowdsec-waf.appsecHost" -}}
{{ .Release.Name }}-appsec-service.{{ .Release.Namespace }}:7422
{{- end }}

{{/* shutdownGrace as whole seconds (accepts values like 60s, 2m). */}}
{{- define "crowdsec-waf.shutdownGraceSeconds" -}}
{{- $d := .Values.proxy.timeouts.shutdownGrace | toString -}}
{{- if hasSuffix "m" $d }}{{ mul (trimSuffix "m" $d | int) 60 }}{{ else }}{{ trimSuffix "s" $d | int }}{{ end -}}
{{- end }}

{{- define "crowdsec-waf.validate" -}}
{{- if not (has .Values.waf.mode (list "detect" "block")) }}{{ fail "waf.mode must be 'detect' or 'block'" }}{{ end }}
{{- required "tls.secretName is required (kubernetes.io/tls Secret for incoming TLS)" .Values.tls.secretName | quote | trunc 0 }}
{{- required "upstream.host is required" .Values.upstream.host | quote | trunc 0 }}
{{- end }}
