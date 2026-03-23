{{/*
Chart name
*/}}
{{- define "wazuh.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fullname
*/}}
{{- define "wazuh.fullname" -}}
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
Common labels
*/}}
{{- define "wazuh.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels per component
*/}}
{{- define "wazuh.indexer.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wazuh.name" . }}
app.kubernetes.io/component: indexer
{{- end }}

{{- define "wazuh.manager.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wazuh.name" . }}
app.kubernetes.io/component: manager
{{- end }}

{{- define "wazuh.dashboard.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wazuh.name" . }}
app.kubernetes.io/component: dashboard
{{- end }}

{{- define "wazuh.agent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wazuh.name" . }}
app.kubernetes.io/component: agent
{{- end }}

{{/*
Derived passwords - deterministic from adminPassword, no lookup needed
*/}}
{{- define "wazuh.kibanaserverPassword" -}}
{{- printf "%s-kibanaserver" .Values.security.adminPassword | sha256sum | trunc 20 }}!1A
{{- end }}

{{- define "wazuh.filebeatPassword" -}}
{{- printf "%s-filebeat" .Values.security.adminPassword | sha256sum | trunc 20 }}!1A
{{- end }}

{{- define "wazuh.apiPassword" -}}
{{- printf "%s-api" .Values.security.adminPassword | sha256sum | trunc 20 }}!1A
{{- end }}

{{/*
Secret name helpers - support existingSecret or chart-created secrets
*/}}
{{- define "wazuh.indexerSecretName" -}}
{{- if .Values.security.existingSecrets.indexer -}}
  {{- .Values.security.existingSecrets.indexer -}}
{{- else -}}
  {{- include "wazuh.fullname" . -}}-indexer-credentials
{{- end -}}
{{- end -}}

{{- define "wazuh.apiSecretName" -}}
{{- if .Values.security.existingSecrets.api -}}
  {{- .Values.security.existingSecrets.api -}}
{{- else -}}
  {{- include "wazuh.fullname" . -}}-api-credentials
{{- end -}}
{{- end -}}

{{- define "wazuh.filebeatSecretName" -}}
{{- if .Values.security.existingSecrets.filebeat -}}
  {{- .Values.security.existingSecrets.filebeat -}}
{{- else -}}
  {{- include "wazuh.fullname" . -}}-filebeat-credentials
{{- end -}}
{{- end -}}

{{- define "wazuh.dashboardSecretName" -}}
{{- if .Values.security.existingSecrets.dashboard -}}
  {{- .Values.security.existingSecrets.dashboard -}}
{{- else -}}
  {{- include "wazuh.fullname" . -}}-dashboard-credentials
{{- end -}}
{{- end -}}

{{/*
FQDN helpers - two variants:
- .fqdn = with trailing dot (for DNS resolution, avoids search domain queries)
- .host = without trailing dot (for TLS/HTTPS, must match certificate SANs)
*/}}
{{- define "wazuh.indexer.fqdn" -}}
{{ include "wazuh.fullname" . }}-indexer.{{ .Release.Namespace }}.svc.cluster.local.
{{- end }}

{{- define "wazuh.indexer.host" -}}
{{ include "wazuh.fullname" . }}-indexer.{{ .Release.Namespace }}.svc.cluster.local
{{- end }}

{{- define "wazuh.manager.fqdn" -}}
{{ include "wazuh.fullname" . }}-manager.{{ .Release.Namespace }}.svc.cluster.local.
{{- end }}

{{- define "wazuh.manager.host" -}}
{{ include "wazuh.fullname" . }}-manager.{{ .Release.Namespace }}.svc.cluster.local
{{- end }}

{{- define "wazuh.manager.agents.fqdn" -}}
{{ include "wazuh.fullname" . }}-manager-agents.{{ .Release.Namespace }}.svc.cluster.local.
{{- end }}

{{- define "wazuh.dnsConfig" -}}
dnsConfig:
  options:
    - name: ndots
      value: "1"
{{- end }}

{{/*
Checksum annotations for manager pods - auto-restart on config/secret changes
*/}}
{{- define "wazuh.checksumAnnotations" -}}
checksum/config: {{ include (print $.Template.BasePath "/manager/configmap.yaml") . | sha256sum }}
checksum/shared-config: {{ include (print $.Template.BasePath "/manager/configmap-shared.yaml") . | sha256sum }}
checksum/credentials: {{ include (print $.Template.BasePath "/secrets/api-credentials.yaml") . | sha256sum }}
{{- end }}
