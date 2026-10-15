# Wavelog Helm Chart Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a public, reusable Helm chart for Wavelog. It covers a
bundled MariaDB, declarative and wizard install modes, seeded API keys,
optional JWT-header SSO with an oauth2-proxy sidecar, and DB backups.

**Architecture:**

- **Workload:** one Wavelog pod runs the upstream image. In declarative
  mode, an init container (same image) runs `files/bootstrap.php`.
  Bootstrap renders `config.php`, `database.php` and `sso.php` from the
  image's own templates plus env vars into an `emptyDir`. That emptyDir is
  mounted read-only at `application/config/docker/`. Bootstrap then
  installs the schema if needed, runs migrations, seeds API keys and links
  the admin to an SSO identity.
- **Database:** MariaDB is a chart-owned StatefulSet.
- **SSO:** oauth2-proxy is an optional sidecar that becomes the Service
  target.
- **Testing:** helm-unittest covers templates. Bash e2e scenarios on kind
  cover runtime behavior.

**Tech Stack:** Helm 4 (CI pins v4.2.4), helm-unittest, kubeconform, kind
(CI), PHP 8.5 (inside the Wavelog image only), `docker.io/library/mariadb`,
`quay.io/oauth2-proxy/oauth2-proxy`, bash and curl, and Python 3 with PyJWT
(e2e JWT minting only).

**Spec:** `docs/superpowers/specs/2026-10-15-wavelog-helm-chart-design.md`

**Deviation from spec, deliberate:** the spec says config files are
"rendered by the chart". This plan renders them at pod start, from the
templates inside the running image (`install/config/*.php`,
`application/config/sso.sample.php`). That avoids copying an 800-line
upstream file into the chart, where it would drift between Wavelog
releases. The outcome the spec asks for is unchanged: config comes only
from values and Secrets, it is regenerated on every start, it is
read-only to Apache, and the installer is locked from the first start.

## Global Constraints

- **Public repo.** No PII, personal domains, local paths or
  environment-specific values in any committed file. Use `example.com`,
  callsign `N0CALL` and locator `AA00aa` in examples and tests.
- `Chart.yaml`: `name: wavelog`, `version: 0.1.0`, `appVersion: "3.2.4"`.
  Image `ghcr.io/wavelog/wavelog`, tag defaults to `appVersion`.
- Wavelog Deployment: `replicas: 1` (not a value), `strategy.type: Recreate`.
- Defaults:
  - `install.mode: declarative`
  - `auth.mode: local`
  - `oauth2Proxy.enabled: false`
  - `mariadb.enabled: true`
  - `backup.enabled: false`
  - `ingress.enabled: false`
  - `httpRoute.enabled: false`
  - `networkPolicy.enabled: false`
- MariaDB uses the official image, pinned `docker.io/library/mariadb:11.8`
  (an LTS). It is not a Bitnami subchart.
- In `auth.mode: header`, an empty `auth.header.jwksUri` fails rendering
  with `auth.header.jwksUri is required when auth.mode=header`.
- With the oauth2-proxy sidecar on, the Service exposes only the proxy port
  (4180). Apache's port 80 is never a Service port.
- API keys are upserted by key value. Keys not in values are never deleted.
- Generated secrets (DB passwords, encryption key, admin password) persist
  across upgrades via `lookup`. `existingSecret` always wins over a
  generated Secret.
- Wavelog's cron token is `hash_hmac('sha256','wavelog-cron-v1',$encryption_key)`.
  The encryption key must never be empty or `flossie1234555541`.
- CI: workflows mirror the sibling chart. The `lint-test.yml` jobs are lint
  plus unittest plus kubeconform for every `ci/*.yaml`. `release.yml` is
  triggered by tag `chart-v*` and pushes to
  `oci://ghcr.io/${{ github.repository_owner }}/charts`. `e2e.yml` runs on
  kind.

## Review Focus

1. **Special characters in values:** a password, name or city containing
   `'`, `"`, `$` or `\` must not break the PHP config or the SQL. Pinned
   in Task 3 (unit test on rendered env) and Task 4 (e2e admin password
   `p'a"s$s\w0rd`).
2. **Generated secrets under `helm template`/GitOps renderers where
   `lookup` returns nothing:** an encryption key or DB password that
   regenerates silently on every render breaks cron and DB auth. Pinned
   in Task 2 and Task 3: with `existingSecret` set, no generated Secret
   renders. NOTES.txt and README warn to use `existingSecret` with
   non-Helm renderers.
3. **A partially installed database** (first-run crash mid-`install.sql`):
   bootstrap must fail loudly, not reinstall over it or report success.
   Pinned in Task 4 (e2e: drop the `users` table and keep the others; the
   init container exits non-zero with `partial install detected`).
4. **`baseUrl` without a trailing slash, or missing:** CodeIgniter needs a
   trailing slash. Normalize it, and fail rendering in declarative mode if
   it is empty. Pinned in Task 3.
5. **The database not ready on first start** (MariaDB still initializing):
   bootstrap waits up to `install.dbWaitSeconds` (default 300) rather than
   crash-looping into a half install. Pinned in Task 4. The e2e installs
   Wavelog and MariaDB together, with no pre-wait.

---

## File Structure

```
charts/wavelog/
  Chart.yaml, values.yaml, .helmignore, README.md
  files/bootstrap.php          # declarative init: render config, install, migrate, keys, SSO link
  files/backup.sh              # mariadb-dump + retention
  templates/_helpers.tpl       # names, labels, db host/secret resolution, secret lookups
  templates/deployment.yaml    # Wavelog pod (+ init container, + oauth2-proxy sidecar)
  templates/service.yaml, serviceaccount.yaml, pvc.yaml
  templates/secret-app.yaml    # encryption key, admin password (generated unless existingSecret)
  templates/configmap-bootstrap.yaml  # bootstrap.php + non-secret JSON (extraConfig, sso, apiKeys meta)
  templates/mariadb-statefulset.yaml, mariadb-service.yaml, mariadb-secret.yaml
  templates/backup-cronjob.yaml, backup-pvc.yaml, configmap-backup.yaml
  templates/ingress.yaml, httproute.yaml, networkpolicy.yaml, NOTES.txt
  tests/*_test.yaml            # helm-unittest suites, one per template
  ci/default-values.yaml, wizard-values.yaml, external-db-values.yaml,
     sso-values.yaml, backup-values.yaml, full-values.yaml
test/e2e/
  lib.sh                       # install/uninstall helpers, port-forward, mysql exec, assert helpers
  declarative.sh, wizard.sh, apikeys.sh, sso.sh, backup.sh
  values-*.yaml                # per-scenario values
  mint_jwt.py, jwks-server.yaml  # test IdP: RSA key → JWKS served by a static nginx pod
.github/workflows/lint-test.yml, e2e.yml, release.yml
README.md (repo), .gitignore (exists)
```

## Values Interface (shared by all tasks)

Every task adds only its own keys, using exactly these names:

```yaml
image: {repository: ghcr.io/wavelog/wavelog, tag: "", pullPolicy: IfNotPresent}
imagePullSecrets: []
nameOverride: ""
fullnameOverride: ""
baseUrl: ""                       # e.g. https://wavelog.example.com/
php: {memoryLimit: 256M, uploadMaxFilesize: 64M, postMaxSize: 64M, maxExecutionTime: 600}
cron: {enabled: true}             # false → DISABLE_CRON=true
install:
  mode: declarative               # declarative | wizard
  dbWaitSeconds: 300
  admin: {username: admin, email: admin@example.com, callsign: N0CALL, locator: AA00aa,
          firstName: "", lastName: "", timezone: 0, dxcc: 0, city: "", language: english,
          existingSecret: "", passwordKey: admin-password}
config:
  locator: AA00aa
  callbook: hamqth                # hamqth | qrz | qrzcq | qrzru | qrzcall
  logThreshold: 0
  existingSecret: ""              # keys: encryption-key, callbook-username, callbook-password, qrzcall-token
  extra: {}                       # $config[key] = value, any scalar/list/map
apiKeys: []                       # [{description, rights: r|rw, user, existingSecret, secretKey}]
auth:
  mode: local                     # local | header
  header:
    jwksUri: ""
    headerName: HTTP_X_FORWARDED_ACCESS_TOKEN
    createUsers: false
    allowDirectLogin: true
    hidePasswordField: false
    buttonText: Login with SSO
    logoutUrl: ""
    adminIdentity: {issuer: "", subject: ""}
    extra: {}
oauth2Proxy:
  enabled: false
  image: {repository: quay.io/oauth2-proxy/oauth2-proxy, tag: v7.12.0, pullPolicy: IfNotPresent}
  issuerUrl: ""
  existingSecret: ""              # keys: client-id, client-secret, cookie-secret
  skipAuthRoutes: ["^/index.php/api/"]
  extraArgs: []
  resources: {}
persistence: {enabled: true, storageClass: "", size: 5Gi, accessModes: [ReadWriteOnce], existingClaim: ""}
mariadb:
  enabled: true
  image: {repository: docker.io/library/mariadb, tag: "11.8", pullPolicy: IfNotPresent}
  auth: {database: wavelog, username: wavelog, existingSecret: "",
         passwordKey: mariadb-password, rootPasswordKey: mariadb-root-password}
  persistence: {enabled: true, storageClass: "", size: 8Gi, existingClaim: ""}
  resources: {}
externalDatabase: {host: "", port: 3306, database: wavelog, username: wavelog,
                   existingSecret: "", passwordKey: mariadb-password}
backup:
  enabled: false
  schedule: "0 3 * * *"
  retention: 7
  persistence: {storageClass: "", size: 10Gi, existingClaim: ""}
  resources: {}
service: {type: ClusterIP, port: 80}
ingress: {enabled: false, className: "", annotations: {}, host: "", tls: []}
httpRoute: {enabled: false, annotations: {}, parentRefs: [], hostnames: []}
networkPolicy: {enabled: false}
serviceAccount: {create: true, name: "", annotations: {}}
podAnnotations: {}
podSecurityContext: {}
securityContext: {allowPrivilegeEscalation: false}
resources: {}
nodeSelector: {}
tolerations: []
affinity: {}
```

Helper names in `_helpers.tpl` (later tasks consume these):

- `wavelog.fullname`, `wavelog.labels`, `wavelog.selectorLabels`
- `wavelog.mariadb.fullname`: `<fullname>-mariadb`
- `wavelog.db.host`: the bundled service name, or `externalDatabase.host`
- `wavelog.db.port`, `wavelog.db.name`, `wavelog.db.user`
- `wavelog.db.secretName`, `wavelog.db.passwordKey`
- `wavelog.app.secretName`: `config.existingSecret` or `<fullname>-app`
- `wavelog.admin.secretName`: `install.admin.existingSecret` or `<fullname>-app`
- `wavelog.baseUrl`: normalized with a trailing slash; fails if empty in
  declarative mode.

## Bootstrap Env Interface (`files/bootstrap.php`)

The init container is invoked as `php /bootstrap/bootstrap.php`. It reads
only these env vars:

| Var | Source |
|---|---|
| `WL_CONFIG_DIR` | `/var/www/html/application/config/docker` (emptyDir) |
| `WL_BASE_URL`, `WL_LOCATOR`, `WL_CALLBOOK`, `WL_LOG_THRESHOLD` | values |
| `WL_ENCRYPTION_KEY`, `WL_CALLBOOK_USERNAME`, `WL_CALLBOOK_PASSWORD`, `WL_QRZCALL_TOKEN` | app Secret (optional keys) |
| `WL_DB_HOST`, `WL_DB_PORT`, `WL_DB_NAME`, `WL_DB_USER` / `WL_DB_PASSWORD` | helpers / DB Secret |
| `WL_DB_WAIT_SECONDS` | `install.dbWaitSeconds` |
| `WL_ADMIN_USERNAME`, `_EMAIL`, `_CALLSIGN`, `_LOCATOR`, `_FIRSTNAME`, `_LASTNAME`, `_TIMEZONE`, `_DXCC`, `_CITY`, `_LANGUAGE`, `WL_ADMIN_PASSWORD` | `install.admin` / admin Secret |
| `WL_EXTRA_CONFIG_JSON` | `toJson config.extra` |
| `WL_AUTH_MODE`, `WL_SSO_JSON` | `auth.mode`, `toJson` of `auth.header` minus `adminIdentity` |
| `WL_ADMIN_ISS`, `WL_ADMIN_SUB` | `auth.header.adminIdentity` |
| `WL_API_KEYS_JSON`, `WL_API_KEY_<n>` | `[{description, rights, user}]` and the key for index *n* from its Secret |

Every PHP value written into a config file goes through `var_export()`.
Every SQL value goes through prepared statements; the one exception is
`install.sql`, which uses upstream's own `real_escape_string` +
`password_hash` substitution. Exit codes: 0 on success, non-zero with a
single-line `bootstrap: <reason>` message on failure.

---

### Task 1: Chart skeleton, Wavelog workload, CI lint/unit

**Files:**
- Create: `charts/wavelog/{Chart.yaml,values.yaml,.helmignore}`
- Create: `templates/{_helpers.tpl,deployment.yaml,service.yaml,serviceaccount.yaml,pvc.yaml,NOTES.txt}`
- Create: `charts/wavelog/tests/{deployment,service,pvc}_test.yaml`
- Create: `charts/wavelog/ci/{default-values,wizard-values}.yaml`
- Create: `.github/workflows/lint-test.yml`

**Interfaces:**
- Produces:
  - the naming/label helpers;
  - a Deployment with container `wavelog` on port `http` 80;
  - volume `data` (PVC `<fullname>-data` or emptyDir) mounted via
    `subPath` at `uploads`, `userdata`, `backup` and
    `images/eqsl_card_images` under `/var/www/html/`;
  - in wizard mode only, `subPath: config` mounted at
    `application/config/docker`;
  - an emptyDir `cache` at `application/cache` and `application/logs`.

- [ ] **Step 1:** Install helm-unittest locally:
  `helm plugin install https://github.com/helm-unittest/helm-unittest --version v1.0.3 --verify=false`
  Expected: `helm unittest --help` works.
- [ ] **Step 2: Write failing tests**
  - `deployment_test.yaml`:
    - `replicas == 1`, `strategy.type == Recreate`
    - image is `ghcr.io/wavelog/wavelog:3.2.4`
    - env `PHP_MEMORY_LIMIT=256M`
    - `cron.enabled=false` → env `DISABLE_CRON=true`
    - liveness and readiness `httpGet.path == /index.php/user/login`
    - wizard mode → a volumeMount with `subPath: config`, mountPath
      `/var/www/html/application/config/docker`
  - `pvc_test.yaml`:
    - storage `5Gi`
    - no PVC when `persistence.existingClaim=foo`, and the Deployment
      uses claimName `foo`
    - `persistence.enabled=false` → emptyDir
  - `service_test.yaml`: port 80 → targetPort `http`.
- [ ] **Step 3:** Run `helm unittest charts/wavelog`. Expected: FAIL (no templates).
- [ ] **Step 4:** Implement the templates. Probes need `initialDelaySeconds`
  (liveness 30s) so first boot isn't killed. Before finalizing, confirm the
  probe path returns 200 unauthenticated in the image. If it doesn't, pick
  the login route that does and update the test.
- [ ] **Step 5:** Run `helm unittest charts/wavelog && helm lint --strict charts/wavelog -f charts/wavelog/ci/wizard-values.yaml`. Expected: PASS.
  (Default values fail until Task 3 adds `baseUrl` handling, so
  `ci/default-values.yaml` sets `baseUrl: https://wavelog.example.com/`
  and `install.mode: wizard` until then.)
- [ ] **Step 6:** Write `lint-test.yml`:
  - Job `lint`: setup-helm v4.2.4, install the helm-unittest plugin, then
    run `helm lint --strict` for each `ci/*.yaml` and `helm unittest charts/wavelog`.
  - Job `validate`: for each `ci/*.yaml`, run
    `helm template ... | kubeconform -strict -summary -ignore-missing-schemas`.
    `-ignore-missing-schemas` is there for HTTPRoute later.
- [ ] **Step 7:** Commit `feat: chart skeleton with Wavelog workload`.

### Task 2: Bundled MariaDB and external database

**Files:**
- Create: `templates/{mariadb-statefulset,mariadb-service,mariadb-secret}.yaml`
- Create: `tests/mariadb_test.yaml`, `ci/external-db-values.yaml`
- Modify: `templates/_helpers.tpl` (db helpers), `values.yaml`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces:
  - `wavelog.db.*` helpers;
  - Secret `<fullname>-mariadb` with keys `mariadb-password` and
    `mariadb-root-password`, generated with `randAlphaNum 32` and preserved
    through `lookup`;
  - Service `<fullname>-mariadb:3306`.

- [ ] **Step 1: Write failing tests** (`mariadb_test.yaml`):
  - The StatefulSet image is `docker.io/library/mariadb:11.8`.
  - Env `MARIADB_DATABASE=wavelog` and `MARIADB_USER=wavelog`, with
    `MARIADB_PASSWORD` and `MARIADB_ROOT_PASSWORD` from secretKeyRef
    `<fullname>-mariadb`.
  - The volumeClaimTemplate is `8Gi`.
  - The readiness probe exec is `healthcheck.sh --connect --innodb_initialized`.
  - `mariadb.auth.existingSecret=dbs` → no Secret is rendered, and refs
    point at `dbs`.
  - `mariadb.enabled=false` with `externalDatabase.host=db.example.com`
    → no StatefulSet, Service or Secret, and the `wavelog.db.host` helper
    renders `db.example.com` (asserted later through Deployment env in
    Task 3).
  - `mariadb.enabled=false` with an empty host → render fails with
    `externalDatabase.host is required when mariadb.enabled=false`.
- [ ] **Step 2:** Run `helm unittest charts/wavelog`. Expected: FAIL.
- [ ] **Step 3:** Implement. The StatefulSet uses `podManagementPolicy:
  OrderedReady`, 1 replica, mounts `/var/lib/mysql`, and runs as the image
  default. Secret generation pattern: when `lookup` finds the existing
  Secret, reuse its data; otherwise use `randAlphaNum 32`.
- [ ] **Step 4:** Run `helm unittest charts/wavelog`. Expected: PASS.
- [ ] **Step 5:** Commit `feat: bundled MariaDB StatefulSet and external DB support`.

### Task 3: Declarative config rendering (bootstrap, part 1)

**Files:**
- Create: `files/bootstrap.php` (render phase only)
- Create: `templates/{configmap-bootstrap,secret-app}.yaml`
- Create: `tests/{bootstrap_test,secret_app_test}.yaml`
- Modify: `templates/deployment.yaml`, `_helpers.tpl`, `ci/default-values.yaml`
  (go back to declarative, `baseUrl: https://wavelog.example.com/`)

**Interfaces:**
- Consumes: the `wavelog.db.*` and `wavelog.app.secretName` helpers.
- Produces:
  - the init container `bootstrap` (image = the Wavelog image, command
    `php /bootstrap/bootstrap.php`, env per the Bootstrap Env Interface);
  - emptyDir `config` mounted read-write in `bootstrap` and `readOnly: true`
    in `wavelog`, at `application/config/docker`;
  - ConfigMap `<fullname>-bootstrap` with key `bootstrap.php`;
  - Secret `<fullname>-app` with keys `encryption-key` and
    `admin-password` (each `randAlphaNum 32`, preserved via `lookup`).
  - PHP functions in `bootstrap.php`, used by later phases:
    - `render_config(): void` writes `config.php` and `database.php` to
      `WL_CONFIG_DIR`;
    - `render_sso(): void` (Task 6);
    - `db(): mysqli`;
    - `main(): int` runs the phases in order.

- [ ] **Step 1: Write failing tests:**
  - `bootstrap_test.yaml`:
    - Declarative → `initContainers[0].name == bootstrap`, and the main
      container mounts `config` with `readOnly: true`.
    - Wizard → no initContainers.
    - `baseUrl: https://w.example.com` → env `WL_BASE_URL=https://w.example.com/`.
    - Empty `baseUrl` in declarative → fails with
      `baseUrl is required when install.mode=declarative`.
    - `config.extra: {disable_version_check: true}` → env
      `WL_EXTRA_CONFIG_JSON={"disable_version_check":true}`.
    - `install.admin.city: "O'Brien \"$x\""` → the env value is
      byte-identical (Review Focus 1, render side).
  - `secret_app_test.yaml`:
    - The `encryption-key` and `admin-password` keys exist.
    - `config.existingSecret=s` with `install.admin.existingSecret=s` →
      no app Secret is rendered (Review Focus 2).
- [ ] **Step 2:** Run `helm unittest charts/wavelog`. Expected: FAIL.
- [ ] **Step 3:** Implement `render_config()`:
  - Read `/var/www/html/install/config/config.php` and replace each
    `'%placeholder%'` (quotes included) with `var_export($value, true)`.
    The placeholders are listed in the spec's "facts" section.
  - `directory` is `''`.
  - The callbook username/password go into the placeholders matching
    `WL_CALLBOOK`; other providers get `''`.
  - Replace `$config['auth_header_enable'] = false;` with `true` when
    `WL_AUTH_MODE=header`.
  - Append `$config[<k>] = var_export(<v>)` for each `WL_EXTRA_CONFIG_JSON` entry.
  - Treat `database.php` the same way, with `%HOSTNAME%` (as
    `host:port`, or set `'port'` if the template has it), `%USERNAME%`,
    `%PASSWORD%` and `%DATABASE%`.
  - Fail with `bootstrap: encryption key missing or default` when the
    encryption key is empty or `flossie1234555541`.
- [ ] **Step 4:** Run `helm unittest charts/wavelog`. Expected: PASS.
  Then run
  `helm template t charts/wavelog -f charts/wavelog/ci/default-values.yaml | kubeconform -strict -ignore-missing-schemas`.
  Expected: valid.
- [ ] **Step 5:** Commit `feat: declarative config rendering via bootstrap init container`.

### Task 4: Install, migrations and e2e harness (bootstrap, part 2)

**Files:**
- Modify: `files/bootstrap.php` (adds `wait_for_db`, `install_state`,
  `install_schema` and `run_migrations`)
- Create: `test/e2e/{lib.sh,declarative.sh,wizard.sh,values-declarative.yaml,values-wizard.yaml}`
- Create: `.github/workflows/e2e.yml`

**Interfaces:**
- Consumes: `db()` and `render_config()` from Task 3.
- Produces:
  - `install_state(mysqli): string` returns `empty | installed | partial`;
  - `run_migrations(): void`;
  - helpers in `lib.sh`, used by all later scenarios:
    - `e2e_install <scenario> [helm args]`: namespace `wl-e2e-<scenario>`;
      runs `helm install --wait --timeout 10m`;
    - `e2e_uninstall`;
    - `e2e_url`: sets up a port-forward to the Service and echoes the base URL;
    - `e2e_sql "<query>"`: runs `kubectl exec` on the MariaDB pod with the
      `mariadb` client and prints the result;
    - `assert_eq <expected> <actual> <msg>`, `assert_http <code> <url> [curl args]`;
    - `e2e_restart_wavelog`: deletes the pod and waits for Ready.

- [ ] **Step 1: Write failing e2e scenarios**
  - `declarative.sh` uses admin password `p'a"s$s\w0rd`, via an
    existingSecret the script creates.
    - `e2e_sql "SELECT COUNT(*) FROM users WHERE user_name='admin'"` == `1`.
    - `GET /install/` is not the installer: expect 403 or a redirect, and
      the body does not contain `Install Wavelog`.
    - A login POST with the special-character password, then
      `GET /index.php/dashboard`, returns 200 and the page contains
      `N0CALL`.
    - `e2e_restart_wavelog`, then the user count is still `1` and login
      still works.
    - `e2e_sql "SELECT MAX(version) FROM migrations"` equals
      `migration_version` from `application/config/migration.php` in the
      image (read via `kubectl exec`).
    - **Partial install (Review Focus 3):**
      `e2e_sql "DROP TABLE users"`, then restart. The init container
      exits non-zero and its logs contain `partial install detected`.
    - **DB not ready (Review Focus 5):** the install itself does not
      pre-wait for MariaDB, so it covers this. Also assert the init logs
      contain `waiting for database` at least once, or that the
      first-attempt restartCount is 0.
  - `wizard.sh`:
    - `GET /install/` returns 200 and contains the installer.
    - After a restart it still does (no lock without config).
    - Full click-through is a manual check, listed in the README.
- [ ] **Step 2:** Write `e2e.yml`:
  - Matrix over the scenario scripts.
  - Use `helm/kind-action@v1` and setup-helm v4.2.4.
  - Run `bash test/e2e/<scenario>.sh`.
  - On failure, dump `kubectl get all,events` and the logs for all
    containers (including init).
  - Run on PRs and pushes to main touching `charts/**` or `test/**`.
  - Push the branch. Expected: the scenarios FAIL, because the install
    phases don't exist yet and the users table is never created.
- [ ] **Step 3:** Implement:
  - `wait_for_db()` retries the connection every 3 s until
    `WL_DB_WAIT_SECONDS`. It logs `bootstrap: waiting for database`, then
    fails with `bootstrap: database not reachable after Ns`.
  - `install_state()`:
    - `users` has ≥1 row → `installed`;
    - zero tables in the schema → `empty`;
    - anything else → `partial`.
    - On `partial`, exit with `bootstrap: partial install detected; restore from backup or drop the schema`.
  - `install_schema()` reuses upstream's substitution from
    `install/includes/core/database_class.php::create_tables`. Prefer
    `require` of that class over copying it, if it can run outside the
    installer context. Otherwise copy the substitution list verbatim,
    with a comment pointing at the upstream file.
  - `run_migrations()`: first try
    `php /var/www/html/index.php migrate` with `CI_ENV=docker` and check
    for JSON `"status":"success"`. If CodeIgniter refuses CLI, start
    `php -S 127.0.0.1:8099 -t /var/www/html` in the background and curl
    `/index.php/migrate`. Record which one worked in a code comment.
- [ ] **Step 4:** Run the e2e in CI on the branch. Expected: both scenarios
  PASS. Fix and repeat until green.
- [ ] **Step 5:** Commit `feat: declarative install, migrations, e2e harness`.

### Task 5: Declarative API keys

**Files:**
- Modify: `files/bootstrap.php` (adds `seed_api_keys(mysqli): void`)
- Modify: `templates/deployment.yaml` (env `WL_API_KEYS_JSON` and `WL_API_KEY_<n>`)
- Create: `tests/apikeys_test.yaml`
- Create: `test/e2e/{apikeys.sh,values-apikeys.yaml}`

**Interfaces:**
- Consumes: the Bootstrap Env Interface and `lib.sh`.
- Produces: rows in `api` with `status='active'`, keyed by `key`.

- [ ] **Step 1: Write failing tests**
  - Unit:
    - Two `apiKeys` entries → env `WL_API_KEY_0` and `WL_API_KEY_1`, each
      with a secretKeyRef to its own Secret/key.
    - `WL_API_KEYS_JSON` holds `[{"description":...,"rights":"rw","user":"admin"}, ...]`.
    - `rights: x` → render fails with `apiKeys[].rights must be r or rw`.
  - e2e `apikeys.sh`, with key `wlE2Etestkey0001` (rw) from a Secret:
    - `POST /index.php/api/qso` with `{"key":..., "station_profile_id":"1", "type":"adif", "string":"<call:5>K1ABC<band:3>20m<mode:3>FT8<qso_date:8>20260101<time_on:6>120000<eor>"}`
      → HTTP 201 or 200, with JSON status ok.
    - `e2e_sql "SELECT COUNT(*) FROM api WHERE \`key\`='wlE2Etestkey0001'"` == `1`.
    - Restart → still `1`.
    - Change the description in values and run `helm upgrade` → the row is
      updated, still `1`.
    - A key inserted manually via SQL is still there after upgrade.
    - Confirm station id 1 is the admin's station:
      `SELECT station_id FROM station_profile WHERE user_id=1`. Note the
      result in the README.
- [ ] **Step 2:** Run `helm unittest` and the CI e2e. Expected: FAIL.
- [ ] **Step 3:** Implement `seed_api_keys()`:
  - Resolve `user` → `users.user_id` by `user_name`. If no user is given,
    use the install admin. An unknown user fails with
    `bootstrap: apiKeys user <u> not found`.
  - For an existing key, `UPDATE api SET rights, status='active',
    description, user_id WHERE key=?`; otherwise `INSERT`.
  - Never `DELETE`.
- [ ] **Step 4:** Run the unit tests and e2e. Expected: PASS.
- [ ] **Step 5:** Commit `feat: declarative API key seeding`.

### Task 6: Header SSO and admin identity linking

**Files:**
- Modify: `files/bootstrap.php` (`render_sso(): void`,
  `link_admin_identity(mysqli): void`)
- Modify: `deployment.yaml` env, `_helpers.tpl` validation
- Create: `tests/sso_test.yaml`, `ci/sso-values.yaml`
- Create: `test/e2e/{sso.sh,values-sso.yaml,mint_jwt.py,jwks-server.yaml}`

**Interfaces:**
- Consumes: `render_config()` (the `auth_header_enable` swap from Task 3).
- Produces:
  - `sso.php` in `WL_CONFIG_DIR`;
  - `users.external_account` for the admin set to
    `json_encode(['iss'=>$iss,'sub'=>$sub])`. This must be byte-identical
    to how `Header_auth.php` builds it, so use the same `json_encode`
    call with default flags.

- [ ] **Step 1: Write failing tests**
  - Unit:
    - `auth.mode=header` with empty `jwksUri` → fails with the Global
      Constraints message.
    - Header mode → env `WL_AUTH_MODE=header`, and `WL_SSO_JSON` contains
      `jwksUri` and `createUsers:false`.
    - `adminIdentity` set → `WL_ADMIN_ISS` and `WL_ADMIN_SUB` are present.
    - Local mode → no SSO env.
  - e2e `sso.sh`:
    - `jwks-server.yaml` is an nginx pod serving a JWKS ConfigMap.
      `mint_jwt.py` generates the RSA key, the JWKS and RS256 tokens
      with `iss=https://idp.example.test`, `sub=e2e-subject-1`,
      `preferred_username`, `email`, `callsign`, `typ=Bearer`, and
      `exp`/`iat` set to now.
    - Install with `auth.mode=header`, `jwksUri` pointing at that service,
      and `adminIdentity` set to the same iss/sub.
    - Port-forward straight to Apache (pod port 80; no sidecar in this
      scenario). Send the header-auth login request (the `Header_auth`
      controller route) with `X-Forwarded-Access-Token: <token>`. The
      session lands as user `admin`: the dashboard shows `N0CALL`, and
      the user count is still `1`.
    - A token signed with a different key is rejected, and the user count
      is still `1`.
    - Restart → the `external_account` value is unchanged.
- [ ] **Step 2:** Run the unit tests and e2e. Expected: FAIL.
- [ ] **Step 3:** Implement:
  - `render_sso()`: copy `application/config/sso.sample.php` and set each
    `$config['auth_header_*']` from `WL_SSO_JSON` via `var_export`. Map
    each camelCase key to its upstream key (e.g. `jwksUri` →
    `auth_header_jwks_uri`, `createUsers` → `auth_header_create`).
    Append entries from `extra` verbatim by key.
  - `link_admin_identity()`: run `UPDATE users SET external_account=? WHERE user_name=?`.
    It runs only when both iss and sub are set. If another user already
    holds that `external_account`, fail with
    `bootstrap: SSO identity already linked to another user`.
- [ ] **Step 4:** Run the unit tests and e2e. Expected: PASS.
- [ ] **Step 5:** Commit `feat: JWT header SSO with declarative admin identity link`.

### Task 7: oauth2-proxy sidecar

**Files:**
- Modify: `templates/deployment.yaml`, `service.yaml`
- Create: `tests/oauth2proxy_test.yaml`
- Modify: `test/e2e/sso.sh` (adds a sidecar phase)

**Interfaces:**
- Consumes: Task 6 header mode.
- Produces: container `oauth2-proxy` on port `proxy` 4180. When enabled,
  the Service `targetPort` is `proxy`.

- [ ] **Step 1: Write failing tests**
  - Unit:
    - Enabled → a second container whose args include
      `--http-address=0.0.0.0:4180`, `--upstream=http://127.0.0.1:80/`,
      `--provider=oidc`, `--oidc-issuer-url=<issuerUrl>`,
      `--pass-access-token=true`, `--set-xauthrequest=true`,
      `--skip-auth-route=^/index.php/api/`, `--reverse-proxy=true` and
      `--email-domain=*`.
    - The client and cookie secrets come from `existingSecret` keys
      `client-id`, `client-secret` and `cookie-secret`.
    - The Service targetPort is `proxy`, and no Service port maps to 80.
    - Enabled with `auth.mode=local` → fails with
      `oauth2Proxy requires auth.mode=header`.
    - Empty `issuerUrl` or `existingSecret` → fails.
  - e2e (sidecar phase in `sso.sh`), with the issuer set to the test
    JWKS/discovery stub and `--skip-oidc-discovery` plus explicit URLs if
    the stub lacks discovery:
    - `GET /` through the Service → 302 to the issuer.
    - `POST /index.php/api/qso` with the seeded key through the Service →
      not 302, and the QSO is accepted.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Confirm that oauth2-proxy forwards the access
  token as `X-Forwarded-Access-Token` with `--pass-access-token`. Wavelog
  reads that by default. If the header differs, set
  `auth.header.headerName` accordingly in the e2e values and document it.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat: optional oauth2-proxy sidecar for SSO`.

### Task 8: Database backups

**Files:**
- Create: `files/backup.sh`
- Create: `templates/{backup-cronjob,backup-pvc,configmap-backup}.yaml`
- Create: `tests/backup_test.yaml`, `ci/backup-values.yaml`
- Create: `test/e2e/{backup.sh,values-backup.yaml}`

**Interfaces:**
- Consumes: the `wavelog.db.*` helpers.
- Produces: a CronJob `<fullname>-backup` (MariaDB image, `concurrencyPolicy: Forbid`).
  Dumps go to `/backup/wavelog-YYYYmmddTHHMMSSZ.sql.gz` and the newest
  `retention` dumps are kept.

- [ ] **Step 1: Write failing tests**
  - Unit:
    - Disabled → nothing renders.
    - Enabled → schedule `0 3 * * *`, a PVC of `10Gi`, and
      `existingClaim` honored.
    - Env `RETENTION=7`, plus DB host and password from the DB Secret.
    - Works with `mariadb.enabled=false` and an external DB.
  - e2e `backup.sh`:
    - Seed a QSO.
    - `kubectl create job --from=cronjob/<fullname>-backup b1`, then wait
      for completion. The file exists.
    - Run it 8 times with `retention: 2` → exactly 2 files.
    - Delete the QSO, restore the newest dump with
      `gunzip | mariadb` into the bundled DB, and the QSO is back.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement `backup.sh` with `set -euo pipefail`, then
  `mariadb-dump --single-transaction --routines --triggers | gzip`, and
  retention via `ls -1t | tail -n +$((RETENTION+1)) | xargs -r rm`.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5:** Commit `feat: scheduled MariaDB backups`.

### Task 9: Exposure, NetworkPolicy, docs and release

**Files:**
- Create: `templates/{ingress,httproute,networkpolicy}.yaml`
- Create: `tests/{ingress,httproute,networkpolicy}_test.yaml`
- Create: `ci/full-values.yaml`
- Create: `charts/wavelog/README.md`, repo `README.md`
- Create: `.github/workflows/release.yml`
- Modify: `templates/NOTES.txt`

**Interfaces:**
- Consumes: all values above.

- [ ] **Step 1: Write failing tests**
  - Ingress: disabled by default; enabled with host `wavelog.example.com`
    → backend is the Service's named port.
  - HTTPRoute: `gateway.networking.k8s.io/v1`, with parentRefs and
    hostnames from values, and backendRef port = the Service port.
  - NetworkPolicy, when enabled:
    - MariaDB ingress is allowed only from pods with Wavelog
      selectorLabels and from the backup job's label
      `app.kubernetes.io/component: backup`.
    - The Wavelog pod accepts ingress on its Service target port only.
- [ ] **Step 2:** Run `helm unittest`. Expected: FAIL.
- [ ] **Step 3:** Implement. Write NOTES.txt:
  - Wizard: go to `<baseUrl>install/` and enter DB host, name and user.
  - Declarative: how to read the generated admin password with
    `kubectl get secret`.
  - A warning when any generated secret is in use: pin it via
    `existingSecret` before using non-Helm renderers (Review Focus 2).
- [ ] **Step 4:** Write the READMEs:
  - A values table.
  - Examples for: declarative, wizard, external DB, API keys plus a
    forwarder (`station_profile_id`, the result from Task 5), and SSO with
    a generic OIDC IdP. The SSO example must state that the IdP has to
    issue JWT access tokens and needs `adminIdentity` to land on the
    admin account.
  - Backups and restore.
  - The wizard click-through as a manual check.
  - No environment-specific content.
- [ ] **Step 5:** `release.yml`: copy the sibling pattern. Trigger on tag
  `chart-v*`, then package, create a GitHub Release with the `.tgz`, and
  `helm push` to `oci://ghcr.io/${{ github.repository_owner }}/charts`.
- [ ] **Step 6:** Run
  `helm unittest charts/wavelog && for f in charts/wavelog/ci/*.yaml; do helm lint --strict charts/wavelog -f $f; done`.
  Expected: all PASS. Then check for leaks with
  `git grep -nIiE '/Users/|/home/[a-z]' -- .`, plus the operator's
  private term list, which is kept outside the repo. Expected: no output.
- [ ] **Step 7:** Commit `feat: ingress, HTTPRoute, NetworkPolicy, docs, release workflow`.

---

## Out of this plan

- Creating the GitHub repo, pushing, tagging `chart-v0.1.0`, and deploying to
  any particular cluster. These follow merge, need the operator's
  go-ahead, and their details live outside this public repo.
