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
{{- " " }}/var/www/html/application/config/docker
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
- name: cache
  mountPath: /var/www/html/application/cache
  subPath: cache
- name: cache
  mountPath: /var/www/html/application/logs
  subPath: logs
{{- end -}}

{{/*
Where Wavelog reads its generated config. Wizard mode persists it on the data
volume; declarative mode re-renders it on every start into an emptyDir.
Callers add readOnly for the main container.
*/}}
{{- define "wavelog.configMount" -}}
{{- if eq .Values.install.mode "wizard" -}}
- name: data
  mountPath: /var/www/html/application/config/docker
  subPath: config
{{- else -}}
- name: config
  mountPath: /var/www/html/application/config/docker
{{- end -}}
{{- end -}}

{{- define "wavelog.app.secretName" -}}
{{- default (printf "%s-app" (include "wavelog.fullname" .)) .Values.config.existingSecret -}}
{{- end -}}

{{- define "wavelog.admin.secretName" -}}
{{- default (printf "%s-app" (include "wavelog.fullname" .)) .Values.install.admin.existingSecret -}}
{{- end -}}

{{/* Public URL with exactly one trailing slash; required in declarative mode. */}}
{{- define "wavelog.baseUrl" -}}
{{- if eq .Values.install.mode "declarative" -}}
{{- $_ := required "baseUrl is required when install.mode=declarative" .Values.baseUrl -}}
{{- end -}}
{{- if .Values.baseUrl -}}{{- printf "%s/" (trimSuffix "/" .Values.baseUrl) -}}{{- end -}}
{{- end -}}

{{/*
Labels selecting Wavelog application pods only. The component label keeps the
Wavelog Service and Deployment from also matching MariaDB pods.
*/}}
{{- define "wavelog.appSelectorLabels" -}}
{{ include "wavelog.selectorLabels" . }}
app.kubernetes.io/component: wavelog
{{- end -}}

{{- define "wavelog.mariadb.selectorLabels" -}}
{{ include "wavelog.selectorLabels" . }}
app.kubernetes.io/component: mariadb
{{- end -}}

{{- define "wavelog.mariadb.secretName" -}}
{{- default (include "wavelog.mariadb.fullname" .) .Values.mariadb.auth.existingSecret -}}
{{- end -}}

{{/* Database host: the bundled Service, or externalDatabase.host (required). */}}
{{- define "wavelog.db.host" -}}
{{- if .Values.mariadb.enabled -}}
{{- include "wavelog.mariadb.fullname" . -}}
{{- else -}}
{{- required "externalDatabase.host is required when mariadb.enabled=false" .Values.externalDatabase.host -}}
{{- end -}}
{{- end -}}

{{- define "wavelog.db.port" -}}
{{- if .Values.mariadb.enabled -}}3306{{- else -}}{{- .Values.externalDatabase.port -}}{{- end -}}
{{- end -}}

{{- define "wavelog.db.name" -}}
{{- if .Values.mariadb.enabled -}}{{- .Values.mariadb.auth.database -}}{{- else -}}{{- .Values.externalDatabase.database -}}{{- end -}}
{{- end -}}

{{- define "wavelog.db.user" -}}
{{- if .Values.mariadb.enabled -}}{{- .Values.mariadb.auth.username -}}{{- else -}}{{- .Values.externalDatabase.username -}}{{- end -}}
{{- end -}}

{{- define "wavelog.db.secretName" -}}
{{- if .Values.mariadb.enabled -}}
{{- include "wavelog.mariadb.secretName" . -}}
{{- else -}}
{{- .Values.externalDatabase.existingSecret -}}
{{- end -}}
{{- end -}}

{{- define "wavelog.db.passwordKey" -}}
{{- if .Values.mariadb.enabled -}}{{- .Values.mariadb.auth.passwordKey -}}{{- else -}}{{- .Values.externalDatabase.passwordKey -}}{{- end -}}
{{- end -}}

{{/* Fail fast on invalid auth settings. */}}
{{- define "wavelog.auth.validate" -}}
{{- $mode := default "local" .Values.auth.mode -}}
{{- if not (has $mode (list "local" "header")) -}}
{{- fail "auth.mode must be local or header" -}}
{{- end -}}
{{- if .Values.oauth2Proxy.enabled -}}
{{- if ne $mode "header" -}}
{{- fail "oauth2Proxy requires auth.mode=header" -}}
{{- end -}}
{{- $_ := required "oauth2Proxy.issuerUrl is required when oauth2Proxy.enabled" .Values.oauth2Proxy.issuerUrl -}}
{{- $_ := required "oauth2Proxy.existingSecret is required when oauth2Proxy.enabled" .Values.oauth2Proxy.existingSecret -}}
{{- end -}}
{{- if eq $mode "header" -}}
{{- if ne .Values.install.mode "declarative" -}}
{{- fail "auth.mode=header requires install.mode=declarative" -}}
{{- end -}}
{{- $h := .Values.auth.header -}}
{{- $_ := required "auth.header.jwksUri is required when auth.mode=header" $h.jwksUri -}}
{{- /* Keep in sync with WL_SSO_KEYS in files/bootstrap.php. */ -}}
{{- $mapped := list "auth_header_jwks_uri" "auth_header_accesstoken" "auth_header_create" "auth_header_allow_direct_login" "auth_header_hide_password_field" "auth_header_text" "auth_header_url_logout" -}}
{{- range $k, $_ := ($h.extra | default dict) -}}
{{- if has $k $mapped -}}
{{- fail (printf "auth.header.extra must not set %s; use the dedicated auth.header value" $k) -}}
{{- end -}}
{{- end -}}
{{- $id := $h.adminIdentity | default dict -}}
{{- if ne (empty $id.issuer) (empty $id.subject) -}}
{{- fail "auth.header.adminIdentity needs both issuer and subject" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "wavelog.backup.claimName" -}}
{{- if .Values.backup.persistence.existingClaim -}}
{{- .Values.backup.persistence.existingClaim -}}
{{- else -}}
{{- printf "%s-backup" (include "wavelog.fullname" .) -}}
{{- end -}}
{{- end -}}

{{- define "wavelog.backup.selectorLabels" -}}
{{ include "wavelog.selectorLabels" . }}
app.kubernetes.io/component: backup
{{- end -}}
