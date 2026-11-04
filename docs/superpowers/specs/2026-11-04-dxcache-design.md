# DXCache in the wavelog chart: design

Date: 2026-11-04
Status: approved

## Intent

Wavelog's DX cluster view and bandmap read spots from a "DXCache" HTTP API.
The default is the shared public instance at `https://dxc.wavelog.org/dxcache`.
The operator wants spots from DX cluster nodes they pick (starting with the
DXSpider node `dm3ks.de:7300`, which carries POTA and SOTA spots in its
stream), merged with other nodes into one feed. They've seen different spots
on different nodes and want the union.

The only consumer is the operator's own Wavelog instance. Nothing outside
the cluster reads these spots.

## Goals

- Optional (`dxcache.enabled`, default `false`) DXCache component in the
  wavelog chart, running upstream DXClusterAPI.
- Several DX cluster nodes, configured as a list in values and merged into
  one spot cache.
- Fully declarative wiring. When enabled, Wavelog's `dxcache_url` points at
  the in-cluster DXCache, and DXCache gets a Wavelog API key for DXCC
  lookups, with no manual steps in the UI.
- Spot and DXCC caches survive pod restarts.

## Non-goals

- Exposing DXCache outside the cluster (no Ingress, no HTTPRoute, no
  external auth).
- Posting spots back to cluster nodes. Neither Wavelog nor DXCache can do
  this. It would be new upstream work in both projects.
- A separate reusable DXCache chart.
- HA or more than one DXCache replica.
- A custom DXCache image.

## Anti-goals

- Two DXCache pods logged in to the same node with the same callsign at
  once (for example during a rolling update). DXSpider nodes drop duplicate
  logins, so this causes reconnect loops.
- Spots silently dropped because DXCC lookups fail. DXCache drops any spot
  whose spotter or spotted call can't be looked up in Wavelog, and caches
  the failure for 5 minutes. Telnet streams don't replay, so a broken or
  missing loopback key means an empty spot list, not a degraded one.
- Wavelog left pointing at a dead in-cluster URL after `dxcache.enabled` is
  turned off.
- The operator's callsign, or any other PII, in chart defaults, CI values or
  docs. The chart repo is public-bound. See `ci/` and `test/e2e/` values for
  the `N0CALL` convention.
- Cluster passwords in plain ConfigMaps or pod specs.

## Facts about upstream

### DXClusterAPI (int2001/DXClusterAPI, v1.5.8)

- Image `ghcr.io/int2001/dxclusterapi`, tagged per semver release (`1.5.8`,
  `1.5`, `1`, `latest`). Base `oven/bun:1`, `USER bun`, entrypoint
  `bun run index.js`, workdir `/usr/src/app`.
- Configured entirely by env vars (`.env.sample` lists them all):
  - `WEBPORT` (default 3000), `BASEURL` (default empty).
  - `CLUSTERS`: a JSON array of
    `{host, port, loginPrompt, call, password, cluster, customCommand?}`.
    `cluster` is a display name. `customCommand` is sent once after login.
  - `POTA_ENABLED`, `SOTA_ENABLED` (on upstream), `RBN_ENABLED` (off), plus
    their polling and feed settings.
  - `MAXCACHE` (500), `SPOT_MAX_AGE` (120 min), `API_SPOT_LIMIT` (200; caps
    API v1 `/spots`).
  - `WAVELOG_URL` / `WAVELOG_KEY`: the full lookup URL. DXCache POSTs JSON
    `{key, callsign}` to it.
  - `MAX_CONCURRENT_DXCC`, `DXCC_CACHE_MAX_SIZE`.
  - `API_V1_ENABLED`, `API_V2_ENABLED`, `LIVE_PAGE_ENABLED`,
    `WEBSOCKET_ENABLED`, `ANALYTICS_ENABLED`, `RATE_LIMITER_ENABLED`,
    `FILE_LOGGING_ENABLED`, `PERSISTENCE_ENABLED`, `PERSISTENCE_INTERVAL`,
    `PERSISTENCE_PATH`, `TRUST_PROXY`, `MODE`.
- Writes to `/usr/src/app/data` (spot cache, DXCC cache,
  `failed_lookups.json`) and `/usr/src/app/logs` (when file logging is on).
- `GET /health` is exempt from rate limiting. `/metrics` (Prometheus) is
  always on.
- Merges duplicate spots by `spotted + dxcc_spotted.cont`, keeping the newest
  (`app.js` `generateSpotKey`).
- **Drops spots when a DXCC lookup fails** (`app.js` "DXCC Validation",
  around line 1640) for either the spotter or the spotted call. Failed
  lookups are cached for 5 minutes (`DXCC_FAILED_CACHE_TTL`). So a working
  Wavelog lookup is required, not optional.
- `package.json` in the `v1.5.8` tag still says `2.0.0`. The tag (commit
  `1388fc7`) is what the `1.5.8` image is built from (docker-image workflow
  run on `v1.5.8` succeeded). The env table above was read from that tag.
- The Dockerfile runs `mkdir -p logs data` before `USER bun`, so those
  directories are root-owned in the image. Mounted volumes need `fsGroup`
  set to the `bun` gid.

### Wavelog (3.2.4)

- `Dxcluster_model` fetches spots server-side with curl from
  `{dxcache_url}/spots/` or `/spots/{band}`, and `{dxcache_url}/spot/{qrg}`.
  An empty `dxcache_url` means the public default. The browser never talks
  to DXCache directly (the builder should confirm this for the bandmap JS).
- `dxcache_url` is a row in the `options` table (read through `OptionsLib`).
  It is not a `config.php` key, so `config.extra` cannot set it.
- `/index.php/api/lookup` takes `{key, callsign}` and needs any active API
  key (read rights are enough).

### This chart today

- `bootstrap.php` (init container, declarative mode only) already upserts
  API keys (`seed_api_keys`) and enables cron jobs. Values become env vars
  (`WL_API_KEYS_JSON`, `WL_API_KEY_<n>`).
- `<fullname>-app` Secret: chart-generated secrets, kept across upgrades
  with `lookup` and `helm.sh/resource-policy: keep`. It is only rendered in
  declarative mode when a generated secret is needed.
- NetworkPolicy (optional) covers ingress only. Egress is unrestricted.
- With `oauth2Proxy.enabled`, the Service port maps to the proxy, and
  `^/index.php/api/` is in `skipAuthRoutes`. In `auth.mode=header`, API
  calls with a key bypass SSO.

## Approaches considered

1. **A DXCache Deployment inside the wavelog chart (chosen).** Its own
   Deployment, Service and PVC, gated by `dxcache.enabled`, with bootstrap
   wiring Wavelog to it. It restarts independently of Wavelog, the chart
   owns the whole loop, and it fits the existing values and Secret patterns.
2. **A sidecar in the Wavelog pod.** Simplest wiring, but every Wavelog
   rollout drops the telnet sessions, and the two share a lifecycle and
   resources. Rejected.
3. **A separate dxcache chart.** Reusable, but there is only one consumer,
   it adds a second release to version, and something other than the
   wavelog chart would still have to set Wavelog's option. Rejected.

The operator picked 1.

## Design

### Values (`dxcache:`)

```yaml
dxcache:
  enabled: false
  image:
    repository: ghcr.io/int2001/dxclusterapi
    tag: "1.5.8"
    pullPolicy: IfNotPresent
  # Default login callsign for every cluster entry. Use a dedicated SSID
  # (e.g. N0CALL-7) so your own telnet sessions don't collide with it.
  callsign: ""
  clusters: []
  #  - name: DM3KS            # display name -> "cluster"
  #    host: dm3ks.de
  #    port: 7300
  #    call: ""               # default: dxcache.callsign
  #    loginPrompt: "login:"  # default
  #    customCommand: ""      # optional, sent after login
  #    existingSecret: ""     # optional Secret with the login password
  #    passwordKey: password
  # Replace the whole CLUSTERS JSON from a Secret (key clusters-json);
  # when set, clusters/callsign above are ignored.
  existingClustersSecret: ""
  pota: {enabled: true, pollingInterval: 120}
  sota: {enabled: true, pollingInterval: 120}
  rbn:
    enabled: false
    callsign: ""   # default: dxcache.callsign
    spotTimeout: 5
    cwRtty: true
    ft8: false
  maxCache: 1000
  spotMaxAge: 120
  apiSpotLimit: 500
  dxcc:
    maxConcurrent: 2
    cacheMaxSize: 5000
  persistence:
    enabled: true
    storageClass: ""
    size: 1Gi
    existingClaim: ""
  extraEnv: []
  resources: {}
  podSecurityContext: {}
  securityContext: {}
  nodeSelector: {}
  tolerations: []
  affinity: {}
```

My calls on defaults:

- `maxCache` 1000 and `apiSpotLimit` 500, up from upstream's 500/200,
  because several merged nodes produce more spots than a single feed, and
  Wavelog asks `/spots/` for all bands in one call.
- Upstream modules set off: API v2, live page, websocket, analytics, rate
  limiter, file logging (logs go to stdout). Upstream modules left on: API
  v1, enrichment, mode classifier, persistence. Only Wavelog reads this
  instance, so the extra surfaces add nothing. `extraEnv` can switch any of
  them back on.

### Templates

- `dxcache-deployment.yaml`: one replica, `strategy: Recreate` (anti-goal:
  no double login; the PVC is RWO anyway). Container port 3000. Liveness
  and readiness probes on `/health`. Env as above. `CLUSTERS` comes from
  the chart-rendered `<fullname>-dxcache` Secret, or from
  `existingClustersSecret`. Mounts the PVC at `/usr/src/app/data`. Pod and
  container security contexts default to non-root as `bun`. The builder
  confirms the uid and whether `readOnlyRootFilesystem: true` works with
  emptyDirs for `logs/` and `/tmp`. Checksum annotation on the Secret so
  cluster changes roll the pod.
- `dxcache-service.yaml`: ClusterIP `<fullname>-dxcache`, port 3000.
- `dxcache-pvc.yaml`: when `persistence.enabled` and no `existingClaim`.
- `dxcache-secret.yaml`: holds `clusters-json` when `existingClustersSecret`
  is empty. Per-cluster passwords from `existingSecret` are read at render
  time with `lookup`. If the referenced Secret doesn't exist yet (first
  install, `helm template`), fail with a clear message rather than silently
  logging in with no password.
- **Lookup gate (my call):** a small init container on the DXCache pod
  (curl image, or the bun image itself) POSTs `{key, callsign: "DL1AA"}` (or
  any fixed, well-known call) to `WAVELOG_URL` until it gets a 200 with a
  non-empty `cont`. Only then does DXCache start and log in to the nodes.
  This covers first install (the key doesn't exist until bootstrap runs) and
  a broken key. A Wavelog rollout while DXCache is already running still
  drops spots for that window, plus up to 5 minutes for calls that failed
  during it. That's accepted as a known limitation and documented in the
  README; fixing it needs an upstream change (retry instead of drop).
- **Builder:** if `lookup`-at-render proves
  awkward for Flux/GitOps, the fallback is an init container that assembles
  `CLUSTERS` from mounted Secrets. Pick whichever keeps the
  no-plain-password rule with less machinery, and record why.
- `networkpolicy.yaml`: when both `networkPolicy.enabled` and
  `dxcache.enabled`, add a policy allowing ingress to the DXCache pod only
  from the Wavelog app pod, on 3000.
- `validate.yaml`: fail when `dxcache.enabled` and
  - `install.mode` is not `declarative` (the wiring needs bootstrap);
  - no clusters are configured and no `existingClustersSecret` is set;
  - a cluster has no `call` and `dxcache.callsign` is empty;
  - `rbn.enabled` with no callsign.
- Helper labels: a `dxcache` component, with selector labels distinct from
  the app's so the app NetworkPolicy and Service don't match it.

### Loopback API key and `dxcache_url` (bootstrap)

- `secret-app.yaml` gains a generated `dxcache-api-key` (random 32+ chars,
  kept across upgrades the same way as `encryption-key`) when
  `dxcache.enabled`. Extend the render condition so the Secret exists
  whenever any generated key is needed.
- The Wavelog init container gets `WL_DXCACHE_API_KEY` (from that Secret)
  and `WL_DXCACHE_URL` (`http://<fullname>-dxcache.<ns>.svc:3000`, no
  trailing slash), or empty strings when disabled.
- New bootstrap phase `configure_dxcache(mysqli $db)`, run after
  `seed_api_keys`:
  - **Enabled:** upsert the API key with rights `r`, description
    `DXCache (managed by chart)`, owned by the install admin. Reuse
    `seed_api_keys`' upsert logic; don't duplicate it. Then upsert
    `options.dxcache_url` to `WL_DXCACHE_URL`.
  - **Disabled:** if `options.dxcache_url` matches the chart's in-cluster
    URL pattern (`http://<fullname>-dxcache.` prefix), clear it so Wavelog
    falls back to the public default. Leave any other value alone; it
    belongs to the operator. Leave the API key in place, since the chart
    never deletes keys (same rule as `apiKeys`).
  - **Builder:** check the `options` table's columns (`option_name`,
    `option_value`, `autoload`) against the 3.2.4 schema and match how
    `Options_model::update` writes them.
- DXCache env: `WAVELOG_URL` = the Wavelog Service in-cluster URL +
  `/index.php/api/lookup`, using the Service port (80, or 4180 with
  oauth2-proxy, which skips `/index.php/api/`). `WAVELOG_KEY` comes from the
  `<fullname>-app` Secret.

### Docs

- Chart README: a DXCache section with a two-node example (dm3ks.de:7300
  plus dxspots.com:7300, using `N0CALL-7`), the SSID advice, and a note
  that posting spots isn't supported.
- `NOTES.txt`: one line when enabled, saying how to check spots
  (`kubectl port-forward` to the Service, then `curl /spots/`).
- Bump `Chart.yaml` `version` to `0.2.0` (new feature). `appVersion` stays
  Wavelog's.

### Tests

- helm-unittest `tests/dxcache_test.yaml`: off by default renders nothing;
  CLUSTERS JSON shape and defaulting (`call` from `callsign`, default
  `loginPrompt`); `existingClustersSecret` overrides; Recreate strategy;
  validation failures; NetworkPolicy; app Secret gains `dxcache-api-key`;
  init-container env present or empty; oauth2-proxy port in `WAVELOG_URL`.
- `test/e2e/bootstrap_unit.php`: `configure_dxcache` enable sets option and
  key; re-run is idempotent; disable clears only the chart-owned URL.
- e2e scenario `test/e2e/dxcache.sh` on kind/Colima: a fake DXSpider node
  in-cluster (a few lines of busybox `nc`/shell serving a login prompt and
  emitting `DX de` lines) so CI never touches real nodes. Assert that
  DXCache reports the connection, Wavelog's `options.dxcache_url` is set,
  and spots appear through Wavelog's own `/index.php/dxcluster/spots/...`
  endpoint, with DXCC filled in (proving the loopback key works). Since a
  failed lookup drops the spot, any spot appearing at all proves the key
  works. Also assert the count: every distinct fake spot shows up, and the
  same DX sent from two fake nodes shows up once. Add a
  `ci/dxcache-values.yaml` for chart-testing lint.

## Left to the builder

- Exact uid/gid for the `bun` user and the read-only root filesystem
  verdict.
- The format of `DX de` lines the fake node emits, matched to
  `lib/dxcluster.js`'s parser.
- The Wavelog route the e2e uses to read spots, and how it authenticates
  (session vs API).
- The CLUSTERS-password mechanism (render-time `lookup` vs init container),
  per the note above.
