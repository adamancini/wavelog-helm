# wavelog

A Helm chart for [Wavelog](https://www.wavelog.org), the web-based amateur radio logbook
(chart appVersion 3.2.4). It deploys Wavelog with the official MariaDB image, declarative or
wizard-driven installation, optional API keys, header-based SSO, scheduled database
backups, and Ingress or Gateway API exposure.

Wavelog runs as a single replica with a `Recreate` rollout strategy. This is fixed, not a value:
the application keeps state on a ReadWriteOnce volume and runs its own cron.

## Installing

```bash
helm install wavelog oci://ghcr.io/<owner>/charts/wavelog \
  --version 0.1.0 \
  --set baseUrl=https://wavelog.example.com/
```

Replace `<owner>` with the account that publishes the chart. Run `helm get notes wavelog` to
see how to read the generated admin password.

Resource names below use `<fullname>`. It equals the release name when that already contains
"wavelog" (so `helm install wavelog` gives `wavelog`, `wavelog-app`, `wavelog-mariadb`,
`wavelog-backup`), otherwise `<release>-wavelog`. `fullnameOverride` replaces it. Substitute
your value; `<release>` is the Helm release name.

Avoid `helm install --wait` when `backup.enabled=true` and the backup storage class uses
`WaitForFirstConsumer` binding (see [Backups](#backups-and-restore)). `Immediate` classes and
`backup.persistence.existingClaim` are fine.

## Examples

### Declarative (default)

An init container renders the Wavelog configuration, waits for the database, installs the
schema and creates the admin user. Nothing needs to be clicked.

```yaml
baseUrl: https://wavelog.example.com/
install:
  mode: declarative
  admin:
    username: admin
    email: admin@example.com
    callsign: N0CALL
    locator: AA00aa
```

Read the generated admin password:

```bash
kubectl get secret <fullname>-app -o jsonpath='{.data.admin-password}' | base64 -d
```

Generated secrets (database passwords, encryption key, admin password) survive `helm upgrade`
through a `lookup` against the cluster. That does not work with `helm template`,
`helm install --dry-run` or GitOps renderers that never contact the cluster: each render would
produce new values. Before using such a renderer, create the Secrets yourself and reference
them with `config.existingSecret` (key `encryption-key`), `install.admin.existingSecret` and
`mariadb.auth.existingSecret`. An `existingSecret` always wins over a generated one.

The admin password from the Secret is used only at first install. Change it later in the
Wavelog UI; rotating the Secret afterwards does nothing.

If you rotate the app Secret outside Helm (encryption key or admin password), run
`kubectl rollout restart deployment/<fullname>` so the pod picks it up. Changing the
encryption key also invalidates the cron token derived from it.

`install.dbWaitSeconds` bounds how long the init container waits for the database. An
access-denied error (MySQL 1044 or 1045) fails immediately instead of retrying, since a wrong
password will not fix itself.

### Wizard

```yaml
baseUrl: https://wavelog.example.com/
install:
  mode: wizard
```

The chart does not render a configuration or install the schema. Complete Wavelog's web
installer instead; see [Manual wizard check](#manual-wizard-check).

### External database

```yaml
baseUrl: https://wavelog.example.com/
mariadb:
  enabled: false
externalDatabase:
  host: db.example.com
  database: wavelog
  username: wavelog
  existingSecret: wavelog-db   # key: mariadb-password (see externalDatabase.passwordKey)
```

The Secret is required. Backups use `mariadb-dump` 11.8, which verifies TLS by default: a
server with a self-signed certificate needs a certificate the image trusts, or a server that
does not require TLS for the backup user.

### API keys and a forwarder

Keys are upserted by key value on every start. Keys that are not in the values are never
deleted. Declarative mode only.

```bash
kubectl create secret generic wavelog-apikey --from-literal=api-key="$(openssl rand -hex 16)"
```

```yaml
install:
  mode: declarative
apiKeys:
  - description: logger
    rights: rw           # r | rw
    user: admin          # defaults to the install admin
    existingSecret: wavelog-apikey
    secretKey: api-key
```

A forwarder posts QSOs to `/index.php/api/qso` with the key and a `station_profile_id`. On a
fresh declarative install the admin's station location is profile `1`:

```bash
curl -sS https://wavelog.example.com/index.php/api/qso \
  -H 'Content-Type: application/json' \
  -d '{"key":"<api key>","station_profile_id":"1","type":"adif",
       "string":"<call:5>K1ABC<band:3>20m<mode:3>FT8<qso_date:8>20260101<time_on:6>120000<eor>"}'
```

Rotating an API key's Secret value adds the new key but leaves the old key active, because
keys are never pruned. Delete the old key in the Wavelog UI.

### SSO with a generic OIDC identity provider

Wavelog accepts a signed JWT forwarded in a request header by a trusted reverse proxy. The
chart can run an [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) sidecar that does
the OIDC login and forwards the access token.

Requirements:

- The identity provider must issue **JWT access tokens** (not opaque tokens), because Wavelog
  verifies the token signature against the JWKS endpoint.
- Set `auth.header.adminIdentity` (issuer and subject, the token `iss` and `sub` claims) so the
  install admin account is linked to your IdP identity. Without it, an SSO login does not
  land on the admin account.
- `install.mode` must be `declarative`.

```bash
kubectl create secret generic wavelog-oauth2-proxy \
  --from-literal=client-id=wavelog \
  --from-literal=client-secret=<client secret> \
  --from-literal=cookie-secret="$(openssl rand -hex 16)"
```

```yaml
baseUrl: https://wavelog.example.com/
install:
  mode: declarative
auth:
  mode: header
  header:
    jwksUri: https://idp.example.com/realms/example/protocol/openid-connect/certs
    createUsers: false
    adminIdentity:
      issuer: https://idp.example.com/realms/example
      subject: 00000000-0000-0000-0000-000000000001
oauth2Proxy:
  enabled: true
  issuerUrl: https://idp.example.com/realms/example
  existingSecret: wavelog-oauth2-proxy
```

Notes:

- With the sidecar enabled the Service exposes only the proxy (port 4180); Apache's port 80 is
  never a Service port. `oauth2Proxy.skipAuthRoutes` lets API clients reach `/index.php/api/`
  with their API key.
- Only `/index.php/api/` is skipped by default. Forwarders that use the rewrite-style `/api/...`
  path must switch to `/index.php/api/...` or you must add a `skipAuthRoutes` entry.
- Upstream Wavelog does not check the JWT `aud` or an expected `iss`, so any token signed by the
  IdP's keys is accepted. Use a dedicated IdP or client policy if the IdP is shared.
- Use an `https` `jwksUri`.
- Removing `adminIdentity` later does not unlink the admin account.
- On each login Wavelog overwrites the user's name, email and callsign with the claims present
  in the token.
- First and last name (`given_name`, `family_name`) stay editable in the account form, because
  Wavelog requires both to save it and many IdPs leave them out of the access token. Set
  `install.admin.firstName` and `lastName` so the admin account starts with them. Setting
  `auth_headers_claim_config` in `auth.header.extra` replaces the whole claim map, including
  this.

## Exposure

Enable `ingress` (needs `ingress.host`) or `httpRoute` (needs `httpRoute.parentRefs`). Both
route to the Service.

```yaml
ingress:
  enabled: true
  className: nginx
  host: wavelog.example.com
  tls:
    - secretName: wavelog-tls
      hosts: [wavelog.example.com]
```

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: example-gateway
      namespace: gateway-system
  hostnames: [wavelog.example.com]
```

Set `baseUrl` to the public URL; Wavelog builds its links from it.

## NetworkPolicy

`networkPolicy.enabled=true` renders:

- app pod: ingress only on the Service target port (80, or 4180 with the oauth2-proxy sidecar);
- bundled MariaDB: ingress on 3306 only from Wavelog pods, and from backup Job pods when
  `backup.enabled`.

Anything else that must reach MariaDB, such as a restore pod, has to carry the backup pods'
labels (see [Backups and restore](#backups-and-restore)).

Egress is not restricted: Wavelog calls LoTW, Club Log, eQSL, QRZ and the JWKS URI. The app
port accepts traffic from any source, so an ingress controller or gateway in another namespace
needs no extra rule. Your CNI must enforce NetworkPolicy.

## DXCache

[DXCache](https://github.com/int2001/DXClusterAPI) (DXClusterAPI) is an optional component
that connects to DX cluster nodes, POTA, SOTA and optionally the Reverse Beacon Network, and
serves the merged spots to Wavelog's DX cluster page. Set `dxcache.enabled=true` to deploy it
as its own Deployment and Service (port 3000). The chart points Wavelog at it automatically.
It requires `install.mode=declarative`.

A two-node example:

```yaml
dxcache:
  enabled: true
  callsign: N0CALL-7
  clusters:
    - name: DM3KS
      host: dm3ks.de
      port: 7300
    - name: DXSpots
      host: dxspots.com
      port: 7300
```

Use a dedicated SSID such as `N0CALL-7` for `dxcache.callsign`, so your own telnet sessions
with the base call do not collide with the DXCache login.

Some nodes need a password. Reference a Secret per cluster entry:

```yaml
dxcache:
  clusters:
    - name: DM3KS
      host: dm3ks.de
      port: 7300
      existingSecret: dm3ks-login
      passwordKey: password   # default
```

To manage the whole cluster list yourself, set `dxcache.existingClustersSecret` to a Secret
with the key `clusters-json`, holding the JSON array that DXCache reads as `CLUSTERS`. When
set, `dxcache.clusters` and `dxcache.callsign` are ignored.

Check the result:

```console
kubectl -n <namespace> port-forward svc/<fullname>-dxcache 3000
# in another terminal:
curl -s localhost:3000/spots/ | head
```

### DXCache notes and limitations

- The upstream image `ghcr.io/int2001/dxclusterapi` is published for linux/amd64 only. On
  arm64 nodes, build it from the upstream tag (plain JavaScript dependencies, and the base
  image `oven/bun:1` is multi-arch) and point `dxcache.image` at it, or pin the pod to an
  amd64 node with `dxcache.nodeSelector`.
- When a cluster entry uses `existingSecret`, the chart reads the Secret with `lookup` at
  render time. `helm template` and dry-runs without cluster access fail for that
  configuration. GitOps controllers that render in the cluster (such as the Flux
  helm-controller) work.
- DXCache drops spots it cannot resolve to a DXCC entity through Wavelog. A startup gate waits
  until Wavelog's lookup works. Spots that arrive while Wavelog restarts are lost, and calls
  that failed in that window are not retried for up to 5 minutes.
- An entry in `dxcache.extraEnv` replaces the built-in variable of the same name.
- Before rolling back below chart 0.2.0 or reinstalling under another release name, disable
  DXCache first (`helm upgrade --set dxcache.enabled=false`) or clear the URL in Wavelog
  Admin > Options > DXCluster. Otherwise Wavelog keeps pointing at a Service that is gone.
- Editing the content of `dxcache.existingClustersSecret`, or rotating the password in a
  per-cluster `existingSecret`, does not restart the pod until the next `helm upgrade` or
  reconcile. Restart the DXCache deployment manually.
- Upstream always serves `GET /api/v2/dxcc/:callsign`, an unauthenticated proxy to Wavelog's
  lookup using the loopback API key (DXCC data only). Enable `networkPolicy.enabled` to
  restrict DXCache to the Wavelog pod.
- `dxcache.sota.enabled` defaults to `false`. DXCache 1.5.8 polls a SOTA API endpoint that
  has been retired; it still answers HTTP 200 but returns no spots, and DXCache logs nothing
  ([int2001/DXClusterAPI#39](https://github.com/int2001/DXClusterAPI/issues/39)). Many DX
  cluster nodes carry SOTA spots in their own feed (dm3ks.de, for example). Re-enable it once
  an upstream release moves to the current SOTA API.
- Posting spots back to cluster nodes is not supported.
- Wavelog's DX cluster page filters by spotter continent (default EU). To see spots from
  other continents, change the "de" filter in Wavelog's UI.

## Persistence

The data volume (`persistence`) and the backup volume (`backup.persistence`) carry
`helm.sh/resource-policy: keep`, so `helm uninstall` leaves them in place. Set
`persistence.keep` or `backup.persistence.keep` to `false` to let Helm delete them. Remove
kept claims by hand with `kubectl delete pvc`.

The chart-generated Secrets (`<fullname>-app`, and `<fullname>-mariadb` when
`mariadb.persistence.enabled`) carry the same annotation, because the encryption key, admin
password hash and database credentials pair with the kept data. They survive `helm uninstall`
alongside the PVCs; delete the Secrets together with the PVCs for a clean reinstall. A reinstall
with the same release name reuses them through `lookup`.

## Upgrading

Database migrations run automatically when the pod starts. Before bumping `image.tag`, take a
backup: with `backup.enabled=true`, create a Job from the CronJob
(`kubectl create job --from=cronjob/<fullname>-backup pre-upgrade`).

If the bootstrap init container reports "partial install detected", an earlier install was
interrupted after creating only part of the schema. Either restore a backup, or drop the
database schema and let the init container install again.

`mariadb.image.tag` is a floating minor tag (`11.8`). Pin a patch version if you want
reproducible rollouts. A MariaDB major upgrade needs `MARIADB_AUTO_UPGRADE` or a manual
`mariadb-upgrade`; the chart has no extra-env value for the MariaDB container, so run the manual
step or use an external database.

## Backups and restore

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *"
  retention: 7
```

A CronJob runs `mariadb-dump`, gzips it into `wavelog-<timestamp>.sql.gz` on a dedicated PVC
and keeps the newest `retention` dumps. Each dump holds the single application database with
`DROP TABLE IF EXISTS`, so restoring over live data works. Dumps are written under a temp name
and renamed on success; a manual Job started during a scheduled run can remove the other run's
live temp file, so do not overlap them.

Backup pods are labelled `app.kubernetes.io/component: backup` (the NetworkPolicy admits that
label), mount no service account token and use the `RuntimeDefault` seccomp profile. They
start with a root init container that fixes volume ownership, so they do not satisfy the
Kubernetes `restricted` Pod Security Standard.

`helm install --wait` blocks when the backup storage class uses `WaitForFirstConsumer`
binding, because the PVC binds only when the first Job runs. Use an `Immediate` class, set
`backup.persistence.existingClaim` to a bound claim, or install with `--wait=hookOnly`.

Run a one-off backup:

```bash
kubectl create job --from=cronjob/<fullname>-backup manual-backup
```

Restore the newest dump with a throwaway pod that mounts the backup claim. Its labels must match
the backup pods' (`app.kubernetes.io/name` is the chart name unless `nameOverride` is set,
`app.kubernetes.io/instance` is the release name), or `networkPolicy.enabled=true` blocks it from
reaching MariaDB:

```bash
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: wavelog-restore
  labels:
    app.kubernetes.io/name: wavelog
    app.kubernetes.io/instance: <release>
    app.kubernetes.io/component: backup
spec:
  securityContext: {runAsUser: 999, runAsGroup: 999, fsGroup: 999}
  containers:
    - name: sh
      image: docker.io/library/mariadb:11.8
      command: [sleep, "3600"]
      env:
        - {name: DB_HOST, value: "<fullname>-mariadb"}
        - name: MYSQL_PWD
          valueFrom: {secretKeyRef: {name: "<fullname>-mariadb", key: mariadb-password}}
      volumeMounts: [{name: backup, mountPath: /backup, readOnly: true}]
  volumes:
    - name: backup
      persistentVolumeClaim: {claimName: "<fullname>-backup"}
YAML
kubectl wait --for=condition=Ready pod/wavelog-restore
kubectl exec wavelog-restore -- sh -c \
  'gunzip -c "$(ls -1 /backup/wavelog-*.sql.gz | sort | tail -n1)" | mariadb -h "$DB_HOST" -u wavelog wavelog'
kubectl delete pod wavelog-restore
```

For a specific dump, run
`gunzip -c /backup/wavelog-<timestamp>.sql.gz | mariadb -h <fullname>-mariadb -u wavelog wavelog`.
With an external database use `externalDatabase.host`, username and database, and the password
from its Secret.

## Logs

Wavelog writes its application log (one file per UTC day) inside the pod.
The `logs` sidecar streams it to stdout, so errors, including the reason an
SSO login was rejected, show up in your log collector and in:

```console
kubectl logs deploy/<fullname> -c logs
```

`config.logThreshold` sets what is recorded: `1` (errors) by default; raise it
to `2` while debugging. The bootstrap step logs to the `bootstrap` init
container (`kubectl logs <pod> -c bootstrap`).

## Manual wizard check

With `install.mode=wizard`:

1. Install with `baseUrl` set and wait for the pods to be ready.
2. Open `<baseUrl>install/` (port-forward the Service if there is no Ingress).
3. Enter the database host (`<fullname>-mariadb`), name (`wavelog`) and user
   (`wavelog`); take the password from the `<fullname>-mariadb` Secret
   (`mariadb-password`).
4. Finish the installer and log in with the account you created.

## Values

| Key | Default | Description |
|-----|---------|-------------|
| `image.repository` | `ghcr.io/wavelog/wavelog` |  |
| `image.tag` | `""` | Defaults to the chart appVersion. |
| `image.pullPolicy` | `IfNotPresent` |  |
| `imagePullSecrets` | `[]` |  |
| `nameOverride` | `""` |  |
| `fullnameOverride` | `""` |  |
| `baseUrl` | `""` | Public URL of the site, e.g. https://wavelog.example.com/ |
| `php.memoryLimit` | `256M` |  |
| `php.uploadMaxFilesize` | `64M` |  |
| `php.postMaxSize` | `64M` |  |
| `php.maxExecutionTime` | `600` |  |
| `cron.enabled` | `true` | false sets DISABLE_CRON=true |
| `install.mode` | `declarative` | declarative: the bootstrap init container renders config and installs the schema. wizard: use Wavelog's web installer. |
| `install.dbWaitSeconds` | `300` | How long the bootstrap init container waits for the database. Access-denied errors (MySQL 1044/1045) fail immediately instead of retrying. |
| `install.admin.username` | `admin` |  |
| `install.admin.email` | `admin@example.com` |  |
| `install.admin.callsign` | `N0CALL` |  |
| `install.admin.locator` | `AA00aa` |  |
| `install.admin.firstName` | `""` |  |
| `install.admin.lastName` | `""` |  |
| `install.admin.timezone` | `0` |  |
| `install.admin.dxcc` | `0` |  |
| `install.admin.city` | `""` |  |
| `install.admin.language` | `english` |  |
| `install.admin.existingSecret` | `""` | Existing Secret holding the admin password under passwordKey. When unset a password is generated into the <fullname>-app Secret. |
| `install.admin.passwordKey` | `admin-password` |  |
| `config.locator` | `AA00aa` |  |
| `config.callbook` | `hamqth` | hamqth \| qrz \| qrzcq \| qrzru \| qrzcall |
| `config.logThreshold` | `1` | 0 = off, 1 = errors (incl. PHP), 2 = debug, 3 = info, 4 = all. |
| `config.existingSecret` | `""` | Existing Secret with keys: encryption-key and, optionally, callbook-username, callbook-password, qrzcall-token. |
| `config.extra` | `{}` | Extra $config[key] = value entries; any scalar, list or map. |
| `apiKeys` | `[]` | Declarative API keys (install.mode=declarative). Upserted by key value on every start; keys not listed here are never deleted. Each entry: description: free text rights: r \| rw user: Wavelog user name (default: the install admin) existingSecret / secretKey: Secret holding the key (secretKey defaults to api-key) |
| `auth.mode` | `local` | local: Wavelog's own login form. header: also accept a signed JWT access token forwarded in a request header by a trusted reverse proxy (requires install.mode=declarative, which renders sso.php). |
| `auth.header.jwksUri` | `""` | JWKS endpoint used to verify token signatures. Required in header mode. |
| `auth.header.headerName` | `HTTP_X_FORWARDED_ACCESS_TOKEN` | PHP $_SERVER name of the token header (X-Forwarded-Access-Token). |
| `auth.header.createUsers` | `false` | Create a Wavelog user on first login of an unknown identity. |
| `auth.header.allowDirectLogin` | `true` | Keep the username/password form next to the SSO button. |
| `auth.header.hidePasswordField` | `false` |  |
| `auth.header.buttonText` | `Login with SSO` |  |
| `auth.header.logoutUrl` | `""` | Redirect after logout; empty returns to the Wavelog login page. |
| `auth.header.adminIdentity.issuer` | `""` |  |
| `auth.header.adminIdentity.subject` | `""` |  |
| `auth.header.extra` | `{}` | Extra sso.php $config[key] = value entries, written verbatim by key, e.g. auth_headers_claim_config. |
| `oauth2Proxy.enabled` | `false` | Sidecar that performs the OIDC login and forwards the access token to Wavelog as X-Forwarded-Access-Token. Requires auth.mode=header. When on, the Service exposes only the proxy (4180); Apache's port 80 is not a Service port. |
| `oauth2Proxy.image.repository` | `quay.io/oauth2-proxy/oauth2-proxy` |  |
| `oauth2Proxy.image.tag` | `v7.12.0` |  |
| `oauth2Proxy.image.pullPolicy` | `IfNotPresent` |  |
| `oauth2Proxy.issuerUrl` | `""` | OIDC issuer URL. Required when enabled. |
| `oauth2Proxy.existingSecret` | `""` | Existing Secret with keys client-id, client-secret and cookie-secret (16, 24 or 32 bytes). Required when enabled. |
| `oauth2Proxy.skipAuthRoutes` | `["^/index.php/api/"]` | Regexes that bypass login so API clients can use their API key. |
| `oauth2Proxy.extraArgs` | `[]` | Extra command-line arguments, appended verbatim. |
| `oauth2Proxy.resources` | `{}` |  |
| `mariadb.enabled` | `true` | false uses externalDatabase instead of the bundled MariaDB. |
| `mariadb.image.repository` | `docker.io/library/mariadb` |  |
| `mariadb.image.tag` | `"11.8"` |  |
| `mariadb.image.pullPolicy` | `IfNotPresent` |  |
| `mariadb.auth.database` | `wavelog` |  |
| `mariadb.auth.username` | `wavelog` |  |
| `mariadb.auth.existingSecret` | `""` | Existing Secret holding passwordKey and rootPasswordKey; skips generation. |
| `mariadb.auth.passwordKey` | `mariadb-password` |  |
| `mariadb.auth.rootPasswordKey` | `mariadb-root-password` |  |
| `mariadb.persistence.enabled` | `true` |  |
| `mariadb.persistence.storageClass` | `""` |  |
| `mariadb.persistence.size` | `8Gi` |  |
| `mariadb.persistence.existingClaim` | `""` |  |
| `mariadb.resources` | `{}` |  |
| `externalDatabase.host` | `""` |  |
| `externalDatabase.port` | `3306` |  |
| `externalDatabase.database` | `wavelog` |  |
| `externalDatabase.username` | `wavelog` |  |
| `externalDatabase.existingSecret` | `""` |  |
| `externalDatabase.passwordKey` | `mariadb-password` |  |
| `logSidecar.enabled` | `true` | Stream Wavelog's application log to the stdout of a `logs` container. |
| `logSidecar.resources` | `{}` |  |
| `persistence.enabled` | `true` |  |
| `persistence.storageClass` | `""` |  |
| `persistence.size` | `5Gi` |  |
| `persistence.existingClaim` | `""` |  |
| `persistence.keep` | `true` | Annotate the data PVC with helm.sh/resource-policy: keep so `helm uninstall` leaves the data in place. Delete the claim by hand to remove it. |
| `backup.enabled` | `false` |  |
| `backup.schedule` | `"0 3 * * *"` |  |
| `backup.retention` | `7` |  |
| `backup.persistence.storageClass` | `""` |  |
| `backup.persistence.size` | `10Gi` |  |
| `backup.persistence.existingClaim` | `""` |  |
| `backup.persistence.keep` | `true` | Keep the backup PVC on `helm uninstall` (helm.sh/resource-policy: keep). |
| `backup.resources` | `{}` |  |
| `service.type` | `ClusterIP` |  |
| `service.port` | `80` |  |
| `ingress.enabled` | `false` |  |
| `ingress.className` | `""` |  |
| `ingress.annotations` | `{}` |  |
| `ingress.host` | `""` | Required when enabled. Add a tls entry for HTTPS, e.g. - secretName: wavelog-tls hosts: [wavelog.example.com] |
| `ingress.tls` | `[]` |  |
| `httpRoute.enabled` | `false` |  |
| `httpRoute.annotations` | `{}` |  |
| `httpRoute.parentRefs` | `[]` | Gateways to attach to. Required when enabled. |
| `httpRoute.hostnames` | `[]` |  |
| `networkPolicy.enabled` | `false` | Restrict ingress to the app pod (Service target port only) and to MariaDB (Wavelog and backup pods on 3306). Egress is unrestricted. |
| `serviceAccount.create` | `true` |  |
| `serviceAccount.name` | `""` |  |
| `serviceAccount.annotations` | `{}` |  |
| `podAnnotations` | `{}` |  |
| `podSecurityContext` | `{}` |  |
| `securityContext.allowPrivilegeEscalation` | `false` |  |
| `resources` | `{}` |  |
| `nodeSelector` | `{}` |  |
| `tolerations` | `[]` |  |
| `affinity` | `{}` |  |
| `hostAliases` | `[]` | Extra /etc/hosts entries for the Wavelog pod ({ip, hostnames} list). |
| `dxcache.enabled` | `false` | Deploy DXCache (DXClusterAPI) and point Wavelog's DX cluster page at it. Requires install.mode=declarative. |
| `dxcache.image.repository` | `ghcr.io/int2001/dxclusterapi` | Published for linux/amd64 only. |
| `dxcache.image.tag` | `"1.5.8"` |  |
| `dxcache.image.pullPolicy` | `IfNotPresent` |  |
| `dxcache.callsign` | `""` | Default login callsign for every cluster entry. Use a dedicated SSID such as N0CALL-7. |
| `dxcache.clusters` | `[]` | DX cluster nodes. Required unless existingClustersSecret is set. Each entry:<br>name: display name<br>host / port: telnet endpoint (required)<br>call: login callsign (default: dxcache.callsign)<br>loginPrompt: default `login:`<br>customCommand: optional command sent after login<br>existingSecret / passwordKey: Secret holding the login password (passwordKey defaults to password) |
| `dxcache.existingClustersSecret` | `""` | Existing Secret with key clusters-json that replaces the whole CLUSTERS value. When set, clusters and callsign are ignored. |
| `dxcache.pota.enabled` | `true` | Include POTA spots. |
| `dxcache.pota.pollingInterval` | `120` | Polling interval in seconds. |
| `dxcache.sota.enabled` | `false` | Poll the SOTA API for spots. Off because upstream's endpoint is retired (see notes). |
| `dxcache.sota.pollingInterval` | `120` | Polling interval in seconds. |
| `dxcache.rbn.enabled` | `false` | Include Reverse Beacon Network spots. |
| `dxcache.rbn.callsign` | `""` | Login callsign for RBN (default: dxcache.callsign). |
| `dxcache.rbn.spotTimeout` | `5` | Spot timeout in minutes. |
| `dxcache.rbn.cwRtty` | `true` | Include CW and RTTY spots. |
| `dxcache.rbn.ft8` | `false` | Include FT8 spots. |
| `dxcache.maxCache` | `1000` | Maximum number of spots kept. |
| `dxcache.spotMaxAge` | `120` | Maximum age of a spot, in minutes. |
| `dxcache.apiSpotLimit` | `500` | Maximum number of spots returned per API request. |
| `dxcache.dxcc.maxConcurrent` | `2` | Concurrent DXCC lookups against Wavelog. |
| `dxcache.dxcc.cacheMaxSize` | `5000` | Size of the DXCC lookup cache. |
| `dxcache.persistence.enabled` | `true` |  |
| `dxcache.persistence.storageClass` | `""` |  |
| `dxcache.persistence.size` | `1Gi` |  |
| `dxcache.persistence.existingClaim` | `""` |  |
| `dxcache.extraEnv` | `[]` | Extra environment variables for the DXCache container. An entry replaces the built-in variable of the same name. |
| `dxcache.resources` | `{}` |  |
| `dxcache.podSecurityContext` | `{}` |  |
| `dxcache.securityContext` | `{}` |  |
| `dxcache.nodeSelector` | `{}` |  |
| `dxcache.tolerations` | `[]` |  |
| `dxcache.affinity` | `{}` |  |

## Testing

```bash
helm unittest charts/wavelog
for f in charts/wavelog/ci/*.yaml; do helm lint --strict charts/wavelog -f "$f"; done
```

End-to-end scenarios live in `test/e2e` (see the repository README).
