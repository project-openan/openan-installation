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
Bundled-database labels (rendered for the active backend only). Label
values are identical to the historical postgres labels, so selectors stay
stable across upgrades.
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
{{- printf "%s://registry-center:%v" (ternary "https" "http" .Values.registry.tls.enabled) .Values.registry.port }}
{{- else }}
{{- "" }}
{{- end }}
{{- end }}

{{/*
Selected database type (verbatim passthrough): a type listed in
database.backends selects the bundled descriptor when database.bundled;
anything else is an external database.
*/}}
{{- define "openan.dbType" -}}
{{- .Values.database.type | default "postgresql" -}}
{{- end }}

{{/*
Workload name of the active bundled backend (openan-<name>); fails for
external databases because they deploy no database workload.
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
Fail messages mirror validate.yaml exactly (render order is not guaranteed:
registry-center templates run before validate.yaml alphabetically).
*/}}
{{- define "openan.databaseHost" -}}
{{- $backend := index .Values.database.backends (include "openan.dbType" .) -}}
{{- if .Values.database.bundled -}}
{{- if $backend -}}
{{- printf "openan-%s" $backend.name -}}
{{- else -}}
{{- $bundledList := keys .Values.database.backends | sortAlpha | join ", " -}}
{{- fail (printf "database.bundled requires a database.backends entry for type '%s' (bundled: %s)" (include "openan.dbType" .) $bundledList) -}}
{{- end -}}
{{- else -}}
{{- required (printf "database.type '%s' is external: set database.host" (include "openan.dbType" .)) .Values.database.host -}}
{{- end -}}
{{- end -}}
{{- define "openan.databasePort" -}}
{{- $backend := index .Values.database.backends (include "openan.dbType" .) -}}
{{- if ne .Values.database.port nil -}}
{{- .Values.database.port -}}
{{- else if $backend -}}
{{- $backend.port -}}
{{- else -}}
{{- fail (printf "database.type '%s' is external without a known default port; set database.port" (include "openan.dbType" .)) -}}
{{- end -}}
{{- end -}}

{{/*
Credential key of the active bundled backend (postgres-password /
mysql-root-password); external SQL reads the per-service passwordKey instead.
*/}}
{{- define "openan.dbPasswordKey" -}}
{{- $backend := index .Values.database.backends (include "openan.dbType" .) -}}
{{- if $backend -}}{{- $backend.passwordKey -}}{{- else -}}db-password{{- end -}}
{{- end }}
{{/* Probe DNS names must resolve inside the probed Pod, not through a Service
whose endpoints are withheld until readiness succeeds. IP literals need no alias. */}}
{{- define "openan.probeHostAliases" -}}
{{- $key := ternary "REGISTRY_HEALTHCHECK_HOST" "ORCH_HEALTHCHECK_HOST" (eq .component "registry") -}}
{{- $host := toString (default "127.0.0.1" (index .config.extraEnv $key)) -}}
{{- if and (not (regexMatch "^[0-9.]+$" $host)) (not (contains ":" $host)) -}}
hostAliases:
- ip: "127.0.0.1"
  hostnames: [{{ $host | quote }}]
{{- end -}}
{{- end -}}
{{- define "openan.publicScheme" -}}
{{- default (ternary "https" "http" (and .Values.ingress.enabled .Values.ingress.tls.enabled)) .Values.orchestration.publicScheme -}}
{{- end -}}

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
