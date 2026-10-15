{{- define "wavelog.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "wavelog.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "wavelog.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "wavelog.labels" -}}
helm.sh/chart: {{ include "wavelog.chart" . }}
{{ include "wavelog.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "wavelog.selectorLabels" -}}
app.kubernetes.io/name: {{ include "wavelog.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "wavelog.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "wavelog.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{- define "wavelog.mariadb.fullname" -}}
{{- printf "%s-mariadb" (include "wavelog.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "wavelog.dataClaimName" -}}
{{- if .Values.persistence.existingClaim -}}
{{- .Values.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-data" (include "wavelog.fullname" .) -}}
{{- end -}}
{{- end -}}

{{/*
Probe path. Before the web installer has run, Wavelog redirects every page to
/install/, which redirects to itself until a session cookie is presented, so
cookie-less kubelet probes loop. In wizard mode probe a static file instead.
*/}}
{{- define "wavelog.probePath" -}}
{{- if eq .Values.install.mode "wizard" -}}
/favicon.ico
{{- else -}}
/index.php/user/login
{{- end -}}
{{- end -}}
