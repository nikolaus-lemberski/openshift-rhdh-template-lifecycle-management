{{/*
Application name.
*/}}
{{- define "app-deployer.name" -}}
{{- .Values.app.name }}
{{- end }}

{{/*
Namespace name.
*/}}
{{- define "app-deployer.namespace" -}}
{{- .Values.app.namespace.name }}
{{- end }}

{{/*
Full image reference.
*/}}
{{- define "app-deployer.imageRef" -}}
{{- printf "%s:%s" .Values.app.image.repository .Values.app.image.tag }}
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "app-deployer.selectorLabels" -}}
app: {{ include "app-deployer.name" . }}
app.kubernetes.io/name: {{ include "app-deployer.name" . }}
{{- end }}

{{/*
Standard labels.
*/}}
{{- define "app-deployer.labels" -}}
{{ include "app-deployer.selectorLabels" . }}
app.kubernetes.io/part-of: {{ include "app-deployer.name" . }}
app.openshift.io/runtime: {{ .Values.app.runtime }}
backstage.io/kubernetes-id: {{ include "app-deployer.name" . }}
{{- end }}

{{/*
Namespace labels (standard + Istio ambient/waypoint when enabled).
*/}}
{{- define "app-deployer.namespaceLabels" -}}
{{- if .Values.app.namespace.istio.enabled }}
istio.io/dataplane-mode: ambient
{{- end }}
{{- if .Values.app.waypoint.enabled }}
istio.io/use-waypoint: waypoint
{{- end }}
{{- end }}
