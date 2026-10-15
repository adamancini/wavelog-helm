# Wavelog Helm Chart — Design

## Intent

Package [Wavelog](https://github.com/wavelog/wavelog), a web-based amateur
radio logbook, as a Helm chart that runs cleanly on a typical Kubernetes
cluster. The chart should come back fully configured after a redeploy, and
should still offer upstream's out-of-box installer for people who prefer
it.

### Motivating use case

Many operators log contacts in several desktop applications at once:
WSJT-X, GridTracker, JTDX, contest loggers, and SDR control software with
built-in digital modes. Each keeps its own log, and they drift apart. A
common fix is a single network-side logbook that receives every QSO
through Wavelog's HTTP API, from a forwarder on the station LAN (for
example a dashboard or relay that listens to WSJT-X-style UDP broadcasts
and posts each logged QSO). Wavelog then serves as the complete,
browsable copy of the log, with maps, awards and statistics. It can sit
beside the operator's primary desktop logbook rather than replace it.

For that to work unattended, the chart must:

- create the logbook, admin user and API keys from values, with no clicks;
- never duplicate users, keys or QSOs across restarts and upgrades;
- keep the API reachable by forwarders even when the web UI sits behind
  SSO.

## Goals

- A standalone, reusable chart.
- A bundled MariaDB, on by default, that can be swapped for an external
  database.
- Two install modes: **declarative** (everything from values) and
  **wizard** (upstream's web installer).
- API keys seeded declaratively.
- Optional SSO through a JWT header, with an optional oauth2-proxy sidecar.

## Non-goals

- Receiving UDP. Wavelog only speaks HTTP, so forwarding UDP to the API is
  a separate component's job.
- A shared, cluster-wide database or database operator.
- Horizontal scaling or HA for Wavelog.
- A custom Wavelog image.

## Anti-goals (would make this a failure even if it "works")

- Restarts or upgrades that duplicate users, API keys or QSOs.
- Two Wavelog replicas running cron at once, which would double LoTW,
  Club Log and eQSL uploads.
- The `/install` wizard reachable on a declaratively installed instance.
- A logbook that can be lost. The database needs persistent storage and
  regular dumps.
- SSO intercepting API calls and breaking forwarders.
- SSO that a forged header sent straight to the pod can bypass.

## Constraints and facts about upstream (Wavelog 3.2.4)

- **Image:** `ghcr.io/wavelog/wavelog`, built for amd64 and arm64.
  `php:8.5-apache-trixie`, Apache on port 80, running as root. A `wavelog`
  user (uid 999, gid `www-data`) owns the files and runs cron.
- **`CI_ENV=docker`:** config is read from `application/config/docker/`
  (`config.php`, `database.php`, optional `sso.php`).
- **Entrypoint (`docker/entrypoint.sh`):** if both `config.php` and
  `database.php` exist in that directory, it touches `install/.lock`. It
  writes PHP ini settings from `PHP_MEMORY_LIMIT`, `PHP_UPLOAD_MAX_FILESIZE`,
  `PHP_POST_MAX_SIZE` and `PHP_MAX_EXECUTION_TIME`. It starts cron unless
  `DISABLE_CRON=true`. It supports a `PUID`/`PGID` remap.
- **Cron:** `/etc/cron.d/wavelog` curls `http://localhost/index.php/cron/run`
  every minute. The cron manager then calls individual jobs over HTTP at
  the configured base URL, sending an `X-Wavelog-Auth` cron token.
  `config.php` notes the cron manager needs http or https with a valid
  certificate (`cron_allow_insecure`).
- **Writable directories (`docker/writable-dirs`):** `application/cache`,
  `application/config`, `application/logs`, `assets`, `backup`, `updates`,
  `uploads`, `userdata`, `images/eqsl_card_images`, `install`.
- **Database:** MySQL/MariaDB only (`mysqli`).
- **The wizard does, in order:**
  1. Writes `config.php` from `install/config/config.php`. Placeholders:
     `%websiteurl% %directory% %baselocator% %callbook% %encryptionkey%
     %log_threshold%` plus callbook credentials (`%qrz_*% %hamqth_*%
     %qrzcq_*% %qrzru_*% %qrzcall_token%`).
  2. Writes `database.php` from `install/config/database.php`.
  3. Loads `install/assets/install.sql` through `mysqli::multi_query`,
     after substituting `%%FIRSTUSER_NAME/PASS/MAIL/CALL/LOCATOR/FIRSTNAME/
     LASTNAME/TIMEZONE/DXCC/CITY/USERLANGUAGE%%`. The password is
     `password_hash()`ed. This creates the schema, the admin user and the
     first station profile (id 1).
  4. Runs migrations via `GET /index.php/migrate`, which calls
     `$this->migration->latest()`. The current version is 307.
  5. Generates a cron auth token.
  6. Updates DXCC data.
  7. Touches `install/.lock`.
- **API keys:** stored in plain text in table `api` (`key`, `rights` =
  `r` or `rw`, `status` = `active`, `description`, `user_id`). Upstream
  generates keys as `"wl" + 13 hex chars`, but lookup is a plain equality
  match.
- **SSO (`application/config/sso.php`, enabled by `auth_header_enable` in
  `config.php`):** reads a JWT from a header (default
  `HTTP_X_FORWARDED_ACCESS_TOKEN`). If `auth_header_jwks_uri` is set, it
  verifies the signature, exp and nbf. Otherwise it only decodes the
  payload ("low security mode"). Options include auto-creating users,
  allowing direct login, hiding the password field, the button text and
  the logout URL.

## Repository conventions

- Chart at `charts/wavelog/`.
- GitHub Actions: `lint-test.yml` (lint plus template rendering for every
  `ci/` values file) and `release.yml` (triggered by a `chart-v*` tag;
  packages the chart and pushes it to an OCI registry on GHCR).
- No environment-specific values, hostnames, credentials or personal data
  in the repo. Examples use `example.com` and placeholder callsigns.

## Chart design

### Wavelog workload

- A Deployment with `replicas: 1` and `strategy: Recreate`. RWO volumes
  and in-container cron both rule out overlap. No HPA and no PDB.
- Image `ghcr.io/wavelog/wavelog`, tag defaulting to `appVersion`.
- Port 80, served by a ClusterIP Service.
- Liveness and readiness probes over HTTP against a path that returns 200
  before login. The builder picks it, e.g. the login page.
- `env` values for the PHP ini variables, and `DISABLE_CRON` exposed.
- Resources and securityContext overridable. Root stays the default,
  because Apache in the upstream image runs as root.

### Persistence

- One PVC for Wavelog's writable state, mounted with `subPath` per
  directory: `uploads`, `userdata`, `backup`, `images/eqsl_card_images`,
  and `application/config/docker` in wizard mode. Everything else in
  `writable-dirs` (cache, logs, updates) goes on `emptyDir` or the image
  layer, as the builder decides. App code always comes from the image, so
  an upgrade means a tag bump.
- `storageClass`, size, `existingClaim`, and `persistence.enabled`
  (falling back to `emptyDir`) are all exposed.

### Bundled MariaDB

- `mariadb.enabled: true` by default. The chart deploys a StatefulSet with
  its own PVC, using the official `docker.io/library/mariadb` image, not a
  Bitnami subchart. Bitnami no longer publishes free images.
- Credentials (root and app) come from a chart-generated Secret, or from
  `mariadb.auth.existingSecret`. A generated password must survive
  upgrades (`lookup` on the existing Secret).
- `mariadb.enabled: false` with `externalDatabase.{host,port,database,
  username,existingSecret,passwordKey}` points Wavelog elsewhere.
- **Backups:** an optional CronJob (`backup.enabled`, nightly by default)
  runs `mariadb-dump` to a backup PVC (or `existingClaim`), with retention
  of N dumps. It works for bundled and external DBs alike.

### Install modes

`install.mode: declarative | wizard`, default `declarative`.

**`wizard` (upstream OOBE):** the chart deploys Wavelog and its database
and nothing more. `application/config/docker/` lives on the PVC. The user
completes `/install` in a browser. The entrypoint locks the installer on
later starts. NOTES.txt tells the user to go to `/install` and gives the
DB host, name and user to enter.

**`declarative`:**

- `config.php` and `database.php` (and `sso.php` when SSO is on) are
  rendered by the chart from upstream's templates' structure plus values.
  Secrets (DB password, encryption key, callbook credentials) come from
  Secrets. The files are mounted read-only into
  `application/config/docker/`, so the installer is locked from first
  start. Values expose at least: `baseUrl` (→ `%websiteurl%`), `locator`,
  `callbook`, callbook credentials, `logThreshold`, `encryptionKey`
  (generated and preserved via `lookup` when not provided), and a
  free-form `extraConfig` map for any other `$config[...]` keys.
- **A bootstrap step runs before Apache starts** (an init container using
  the same Wavelog image, so it uses upstream's own `install.sql` and PHP):
  1. Wait for the database.
  2. If the schema is absent, load `install.sql` with the `FIRSTUSER`
     placeholders filled from `install.admin.*` values (username, email,
     callsign, locator, first/last name, timezone, DXCC, city, language).
     The password comes from `install.admin.existingSecret` and is hashed
     with PHP `password_hash()`.
  3. Run migrations to latest on every start, so an image bump upgrades
     the schema.
  4. Seed API keys (below).
  5. Make sure a cron auth token exists so in-container cron works.
  6. In `auth.mode: header`, if `auth.header.adminIdentity` is set, link
     the admin user to that SSO identity (see Authentication).
- **Every step must be idempotent.** Re-running on an installed database
  must be a no-op, apart from migrations and key upserts.

### Declarative API keys

```yaml
apiKeys:
  - description: qso-forwarder
    rights: rw            # r | rw
    user: admin           # optional; defaults to the install admin user
    existingSecret: wavelog-api-keys
    secretKey: FORWARDER_KEY
```

- Upsert into `api` keyed on the key value: insert if missing, otherwise
  update rights, status and description. Never duplicate.
- Keys not listed in values are left alone (they may have been created in
  the UI). Pruning is out of scope.
- QSOs posted via the API need a `station_profile_id`. The station created
  by `install.sql` is id 1. Confirm this during the build and document it
  in the README.

### Authentication

`auth.mode: local | header`. The default is **`local`**: Wavelog's own
username and password, no `sso.php`, nothing extra deployed.

`header`:

- Renders `sso.php` from values: header name, JWKS URI, auto-create users,
  allow direct login, hide the password field, button text, logout URL.
  Sets `auth_header_enable` in `config.php`.
- An optional `oauth2Proxy.enabled` sidecar in the Wavelog pod, off by
  default. It handles OIDC against a configurable issuer (any compliant
  IdP, e.g. Authelia, Keycloak, Authentik), passes
  `X-Forwarded-Access-Token` to Apache, and becomes the Service's target
  port when enabled.
  - Skip auth for `/index.php/api/*`. API keys protect it, and forwarders
    must never see an SSO redirect.
  - Client ID, secret and cookie secret come from `existingSecret`.
- **Linking the declared admin to SSO.** Wavelog matches SSO logins only
  through `users.external_account`, which holds the JSON `{"iss": ..., "sub": ...}`
  built from the token's claims (`Header_auth.php`). Without a link, the
  first SSO login auto-creates a new, non-admin user. That user can't see
  the admin's logbook, and creation fails if the username or email
  collides. Auto-create also needs `email` and `callsign` claims, which
  many IdPs don't carry. The chart therefore exposes
  `auth.header.adminIdentity.{issuer,subject}`. In declarative mode, the
  bootstrap step sets the admin's `external_account` to exactly the
  string Wavelog would build, so the operator's SSO login lands on the
  declared admin account. This runs idempotently on every start, so a
  changed subject is picked up. `auth_header_create` stays configurable,
  for sites that want other SSO users auto-provisioned.
- **API callers come through the front door.** Forwarders such as
  dashboard log-sync features often relay from their own server, and may
  refuse in-cluster or private hostnames as an SSRF guard. Expect API
  traffic to arrive through the same ingress as browsers. That makes the
  `/index.php/api/*` skip-auth rule essential, not optional.
- **Forged-header protection:** in `header` mode, `auth_header_jwks_uri`
  must be set (pointing at the IdP's JWKS) so signatures are verified. When
  the sidecar is enabled, the Service must not expose Apache's port
  directly, so nothing in the cluster can skip the proxy.
- The IdP must issue **JWT** access tokens (not opaque ones) for the
  client. Document this in the README, because some IdPs default to
  opaque tokens.

### Other resources

- ServiceAccount (no RBAC), optional Ingress (off by default), optional
  Gateway API HTTPRoute (off by default), NOTES.txt, README with a values
  table and examples for both install modes, SSO, and API-key forwarding.
- Optional NetworkPolicy (off by default). If enabled, MariaDB accepts
  only Wavelog and the backup job.
- `ci/` values files covering: defaults, wizard mode, external DB,
  header auth with sidecar, backups on.

## Testing and verification

- `helm lint` and `helm template` for every `ci/` values file. Check
  which resources exist and which don't per mode (e.g. no `sso.php` in
  `local`, no rendered config in `wizard`).
- A real install on a disposable cluster (kind/k3d), covering:
  - **Declarative:** log in as the declared admin; `/install` is locked;
    POST a QSO to `/index.php/api/qso` with the seeded key (through the
    oauth2-proxy port when the sidecar is on); with a test IdP, an SSO
    login lands on the declared admin account; restart the
    pod and confirm there are no duplicate users or keys; bump the image
    tag and confirm migrations run.
  - **Wizard:** completing `/install` works and survives a restart.
  - **Backup:** the CronJob produces a dump that restores.

## Left to the builder

- Whether bootstrap runs through PHP (reusing upstream install classes) or
  through the `mariadb` client plus a small PHP hashing step, and how
  "already installed" is detected (e.g. presence of the `users` table or
  the `migrations` table).
- How to run migrations without HTTP from an init container. Options
  include invoking CodeIgniter's CLI (`php index.php migrate`) or a small
  PHP script, provided it is idempotent and safe to repeat.
- How the cron token is generated and stored, and whether cron's
  self-calls to `baseUrl` work from inside the pod. If hairpinning through
  the ingress is a problem, point the cron manager at localhost.
- Which upstream config defaults to keep vs. expose as typed values;
  anything else goes through `extraConfig`.
- The probe path, resource defaults, the MariaDB version pin, and backup
  retention defaults.
- How oauth2-proxy handles Wavelog's logout URL.
