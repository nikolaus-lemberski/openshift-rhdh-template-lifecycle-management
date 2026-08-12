{{/*
Application name.
*/}}
{{- define "build-deployer.name" -}}
{{- .Values.name }}
{{- end }}

{{/*
Namespace name.
*/}}
{{- define "build-deployer.namespace" -}}
{{- .Values.namespace.name }}
{{- end }}

{{/*
Build service account name.
*/}}
{{- define "build-deployer.saName" -}}
{{- printf "%s-build" (include "build-deployer.name" .) }}
{{- end }}

{{/*
Full image reference.
*/}}
{{- define "build-deployer.imageRef" -}}
{{- printf "%s/%s/%s:%s" .Values.image.host .Values.image.organization .Values.image.name .Values.image.tag }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "build-deployer.selectorLabels" -}}
app: {{ include "build-deployer.name" . }}
app.kubernetes.io/name: {{ include "build-deployer.name" . }}
{{- end }}

{{/*
Standard labels.
*/}}
{{- define "build-deployer.labels" -}}
{{ include "build-deployer.selectorLabels" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- with .Values.extraLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Namespace labels (standard + Istio when enabled).
*/}}
{{- define "build-deployer.namespaceLabels" -}}
{{ include "build-deployer.labels" . }}
{{- if .Values.namespace.istio.enabled }}
istio.io/dataplane-mode: {{ .Values.namespace.istio.dataplaneMode }}
istio.io/use-waypoint: {{ .Values.namespace.istio.useWaypoint }}
{{- end }}
{{- with .Values.namespace.labels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Pipeline name (used for Pipeline, TriggerBinding, TriggerTemplate).
*/}}
{{- define "build-deployer.pipelineName" -}}
{{- printf "%s-push" (include "build-deployer.name" .) }}
{{- end }}

{{/*
EventListener name.
*/}}
{{- define "build-deployer.listenerName" -}}
{{- printf "%s-listener" (include "build-deployer.name" .) }}
{{- end }}

{{/*
Promote pipeline name.
*/}}
{{- define "build-deployer.promotePipelineName" -}}
{{- printf "%s-tag-promote" (include "build-deployer.name" .) }}
{{- end }}

{{/*
Image reference without tag (for skopeo copy source/dest).
*/}}
{{- define "build-deployer.imageBase" -}}
{{- printf "%s/%s/%s" .Values.image.host .Values.image.organization .Values.image.name }}
{{- end }}

{{/*
Backstage kubernetes-id label value.
*/}}
{{- define "build-deployer.backstageId" -}}
{{- include "build-deployer.name" . }}
{{- end }}
