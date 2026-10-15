# wavelog-helm

A Helm chart for [Wavelog](https://www.wavelog.org), the web-based amateur radio logbook.

- Chart: [`charts/wavelog`](charts/wavelog), with its [README](charts/wavelog/README.md) (values, examples, backup and restore)
- Wavelog 3.2.4, official MariaDB 11.8 image, single replica
- Declarative install (no installer clicks) or Wavelog's web wizard
- API keys, header-based SSO with an optional oauth2-proxy sidecar, scheduled backups
- Ingress or Gateway API HTTPRoute, optional NetworkPolicy

## Quick start

```bash
helm install wavelog oci://ghcr.io/<owner>/charts/wavelog \
  --version 0.1.0 \
  --set baseUrl=https://wavelog.example.com/
```

## Development

Requirements: Helm 4, the [helm-unittest](https://github.com/helm-unittest/helm-unittest)
plugin, kubeconform, yamllint.

```bash
helm unittest charts/wavelog
for f in charts/wavelog/ci/*.yaml; do helm lint --strict charts/wavelog -f "$f"; done
```

`charts/wavelog/ci/*.yaml` are the value sets that CI lints and renders.

### End-to-end tests

`test/e2e` holds scenarios that install the chart into a throwaway namespace and exercise the
real application: `declarative.sh`, `wizard.sh`, `apikeys.sh`, `sso.sh` and `backup.sh`.
They need `helm`, `kubectl` and a disposable cluster. Name it explicitly:

```bash
E2E_KUBE_CONTEXT=kind-wavelog bash test/e2e/declarative.sh
```

The scripts refuse any context that is not `colima` or `kind-*`.

## Releasing

Pushing a tag `chart-vX.Y.Z` packages the chart, creates a GitHub Release with the `.tgz` and
pushes it to `oci://ghcr.io/<owner>/charts`. Bump `version` in `Chart.yaml` first.
