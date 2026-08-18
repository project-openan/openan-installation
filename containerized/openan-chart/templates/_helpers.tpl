{{/*
Copyright (c) 2026 Huawei Technologies Co., Ltd.
All Rights Reserved.
SPDX-License-Identifier: Apache-2.0
*/}}

{{/*
Expand the name of the chart.
*/}}
{{- define "openan.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "openan.fullname" -}}
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
{{- define "openan.labels" -}}
helm.sh/chart: {{ include "openan.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: openan
{{- end }}

{{/*
Registry Center labels
*/}}
{{- define "openan.registry.labels" -}}
{{ include "openan.labels" . }}
app: registry-center
app.kubernetes.io/name: registry-center
app.kubernetes.io/component: registry
{{- end }}

{{/*
Registry Center selector labels
*/}}
{{- define "openan.registry.selectorLabels" -}}
app: registry-center
{{- end }}

{{/*
Orchestration Center labels
*/}}
{{- define "openan.orchestration.labels" -}}
{{ include "openan.labels" . }}
app: orchestration-center
app.kubernetes.io/name: orchestration-center
app.kubernetes.io/component: orchestration
{{- end }}

{{/*
Orchestration Center selector labels
*/}}
{{- define "openan.orchestration.selectorLabels" -}}
app: orchestration-center
{{- end }}

{{/*
PostgreSQL labels
*/}}
{{- define "openan.postgres.labels" -}}
{{ include "openan.labels" . }}
app: openan-postgres
app.kubernetes.io/name: openan-postgres
app.kubernetes.io/component: database
{{- end }}

{{/*
PostgreSQL selector labels
*/}}
{{- define "openan.postgres.selectorLabels" -}}
app: openan-postgres
{{- end }}

{{/*
Workflow Designer labels
*/}}
{{- define "openan.frontend.labels" -}}
{{ include "openan.labels" . }}
app: workflow-designer
app.kubernetes.io/name: workflow-designer
app.kubernetes.io/component: frontend
{{- end }}

{{/*
Workflow Designer selector labels
*/}}
{{- define "openan.frontend.selectorLabels" -}}
app: workflow-designer
{{- end }}

{{/*
Registry Center URL
*/}}
{{- define "openan.registryUrl" -}}
{{- if .Values.orchestration.agentRegistryUrl }}
{{- .Values.orchestration.agentRegistryUrl }}
{{- else if .Values.registry.enabled }}
{{- printf "http://registry-center:%v" .Values.registry.port }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
PostgreSQL host
*/}}
{{- define "openan.postgresHost" -}}
{{- if .Values.postgresql.enabled }}
{{- "openan-postgres" }}
{{- else }}
{{- .Values.postgresql.externalHost }}
{{- end }}
{{- end }}
