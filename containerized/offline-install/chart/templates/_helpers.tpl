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
Bundled-database labels (rendered for the active backend only). The label
values are identical to the historical per-type labels (app:
openan-postgres / openan-mysql), so selectors stay stable across upgrades.
*/}}
{{- define "openan.db.labels" -}}
{{ include "openan.labels" . }}
app: openan-{{ include "openan.dbWorkloadName" . }}
app.kubernetes.io/name: openan-{{ include "openan.dbWorkloadName" . }}
app.kubernetes.io/component: database
{{- end }}

{{/*
Bundled-database selector labels
*/}}
{{- define "openan.db.selectorLabels" -}}
app: openan-{{ include "openan.dbWorkloadName" . }}
{{- end }}

{{/*
Frontend labels
*/}}
{{- define "openan.frontend.labels" -}}
{{ include "openan.labels" . }}
app: openan-frontend
app.kubernetes.io/name: openan-frontend
app.kubernetes.io/component: frontend
{{- end }}

{{/*
Frontend selector labels
*/}}
{{- define "openan.frontend.selectorLabels" -}}
app: openan-frontend
{{- end }}

{{/*
Registry Center URL
*/}}
{{- define "openan.registryUrl" -}}
{{- if .Values.orchestration.agentRegistryUrl }}
{{- .Values.orchestration.agentRegistryUrl }}
{{- else if .Values.registry.enabled }}
{{- printf "%s://registry-center:%v" (include "openan.httpScheme" .) .Values.registry.port }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
HTTP scheme for in-cluster upstreams, honouring the https switch
*/}}
{{- define "openan.httpScheme" -}}
{{- if .Values.https.enabled }}https{{ else }}http{{ end }}
{{- end }}

{{/*
Selected database type (verbatim passthrough): a type listed in
database.backends is bundled; anything else is an external database.
*/}}
{{- define "openan.dbType" -}}
{{- .Values.database.type | default "postgresql" -}}
{{- end }}

{{/*
Workload name of the active bundled backend (openan-<name>); fails for
external types because they deploy no database workload.
*/}}
{{- define "openan.dbWorkloadName" -}}
{{- $backend := index .Values.database.backends (include "openan.dbType" .) -}}
{{- if $backend -}}
{{- $backend.name -}}
{{- else -}}
{{- fail (printf "database.type '%s' has no bundled backend descriptor (external databases deploy no workload)" (include "openan.dbType" .)) -}}
{{- end -}}
{{- end }}

{{/*
Database host: the bundled backend Service, or the external database.host.
*/}}
{{- define "openan.dbHost" -}}
{{- $type := include "openan.dbType" . -}}
{{- $backend := index .Values.database.backends $type -}}
{{- if $backend -}}
{{- printf "openan-%s" $backend.name -}}
{{- else -}}
{{- $bundled := keys .Values.database.backends | sortAlpha | join ", " -}}
{{- required (printf "database.type '%s' is not a bundled backend (bundled: %s); set database.host for an external database" $type $bundled) .Values.database.host -}}
{{- end -}}
{{- end }}

{{/*
Database port: explicit database.port or the backend default (bundled);
external types must set database.port explicitly (no default is known).
*/}}
{{- define "openan.dbPort" -}}
{{- $backend := index .Values.database.backends (include "openan.dbType" .) -}}
{{- if $backend -}}
{{- .Values.database.port | default $backend.port -}}
{{- else -}}
{{- if eq (toString .Values.database.port) "<nil>" -}}
{{- fail (printf "database.type '%s' is external: set database.port (no default port is known for it)" (include "openan.dbType" .)) -}}
{{- end -}}
{{- .Values.database.port -}}
{{- end -}}
{{- end }}

{{/*
Credential Secret key for the application DB_PASSWORD: the backend
descriptor key (bundled) or database.passwordKey (external).
*/}}
{{- define "openan.dbPasswordKey" -}}
{{- $backend := index .Values.database.backends (include "openan.dbType" .) -}}
{{- if $backend -}}
{{- $backend.passwordKey -}}
{{- else -}}
{{- default "password" .Values.database.passwordKey -}}
{{- end -}}
{{- end }}

{{/*
Selected frontend type: portal (default) or workflow-designer
*/}}
{{- define "openan.frontendType" -}}
{{- $t := .Values.frontend.type | default "portal" -}}
{{- if not (or (eq $t "portal") (eq $t "workflow-designer")) -}}
{{- fail (printf "frontend.type must be \"portal\" or \"workflow-designer\", got %q" $t) -}}
{{- end -}}
{{- $t -}}
{{- end }}

{{/*
Frontend container port: portal listens 8080 (unprivileged), designer 80
*/}}
{{- define "openan.frontendContainerPort" -}}
{{- if eq (include "openan.frontendType" .) "portal" -}}
8080
{{- else -}}
80
{{- end }}
{{- end }}

{{/*
Frontend image repository; empty values default selects by frontend type
*/}}
{{- define "openan.frontendImageRepository" -}}
{{- .Values.frontend.image.repository | default (ternary "ghcr.io/project-openan/openan-portal" "ghcr.io/project-openan/workflow-designer" (eq (include "openan.frontendType" .) "portal")) -}}
{{- end }}
