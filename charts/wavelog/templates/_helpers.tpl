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
Readiness probe path. Liveness always uses /favicon.ico so a DB outage never
restarts the pod. Before the web installer has run, Wavelog redirects every page to
/install/, which redirects to itself until a session cookie is presented, so
cookie-less kubelet probes loop. In wizard mode probe a static file instead.
*/}}
{{- define "wavelog.readinessPath" -}}
{{- if eq .Values.install.mode "wizard" -}}
/favicon.ico
{{- else -}}
/index.php/user/login
{{- end -}}
{{- end -}}

{{- define "wavelog.writablePaths" -}}
/var/www/html/uploads /var/www/html/userdata /var/www/html/backup /var/www/html/images/eqsl_card_images /var/www/html/application/cache /var/www/html/application/logs
{{- if eq .Values.install.mode "wizard" }} /var/www/html/application/config/docker{{ end }}
{{- end -}}

{{- define "wavelog.volumeMounts" -}}
- name: data
  mountPath: /var/www/html/uploads
  subPath: uploads
- name: data
  mountPath: /var/www/html/userdata
  subPath: userdata
- name: data
  mountPath: /var/www/html/backup
  subPath: backup
- name: data
  mountPath: /var/www/html/images/eqsl_card_images
  subPath: images/eqsl_card_images
{{- if eq .Values.install.mode "wizard" }}
- name: data
  mountPath: /var/www/html/application/config/docker
  subPath: config
{{- end }}
- name: cache
  mountPath: /var/www/html/application/cache
  subPath: cache
- name: cache
  mountPath: /var/www/html/application/logs
  subPath: logs
{{- end -}}
