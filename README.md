# redskap-actions

GitHub Actions for publishing to [Redskap](https://github.com/scheiblingco/redskap) with **trusted publishing**: the workflow authenticates with its GitHub OIDC ID token, so no Redskap secret has to be stored in the repository.

| Action | What it does |
|---|---|
| [`get-token`](#get-token) | Exchanges the job's GitHub OIDC token for a short-lived Redskap token |
| [`docker-login`](#docker-login) | Logs Docker in to a Redskap OCI registry |
| [`upload`](#upload) | Uploads Helm charts and Debian packages to a Redskap repository |

`docker-login` and `upload` fetch a token automatically unless you pass one in `token`.

## Server setup

Enable GitHub Actions auth on the Redskap instance and add a trust binding that matches your workflow:

```yaml title="config.yaml"
middleware:
  github_actions:
    enabled: true
    audience: https://packages.example.com   # the actions default `audience` to `url`
    exchange_ttl: 15m

repositories:
  bookworm-main:
    frontend: debian
    auth:
      github_trust:
        - id: myapp-tags
          repository: myorg/myapp
          repository_id: "987654321"
          ref: refs/tags/v*
          workflow: .github/workflows/release.yml
          scopes: [write]
```

Trust bindings can also be managed from the web UI (**GitHub Actions**) or the `/api/v1/github-trust` API. See the Redskap auth docs for the full list of binding fields.

## Workflow permissions

Every job that fetches a token needs:

```yaml
permissions:
  id-token: write
  contents: read
```

## get-token

```yaml
- id: redskap
  uses: scheiblingco/redskap-actions/get-token@v1
  with:
    url: https://packages.example.com
    export-env: true          # also sets $REDSKAP_TOKEN for later steps

- run: |
    curl -fsS -T dist/app.deb -H "Authorization: Bearer ${{ steps.redskap.outputs.token }}" \
      "https://packages.example.com/r/bookworm-main/debian/upload?dist=bookworm&component=main"
```

| Input | Default | Description |
|---|---|---|
| `url` | *required* | Base URL of the Redskap instance |
| `audience` | `url` | OIDC audience; must match `middleware.github_actions.audience` |
| `exchange` | `true` | `false` returns the raw GitHub ID token (valid for a few minutes) instead of an exchanged Redskap token |
| `export-env` | `false` | Export the token as `REDSKAP_TOKEN` |

Outputs: `token` (masked), `expires-at`, `subject`.

## docker-login

```yaml
- uses: scheiblingco/redskap-actions/docker-login@v1
  with:
    url: https://packages.example.com
    registry: docker.packages.example.com   # omit for path-style routing

- run: |
    docker build -t docker.packages.example.com/my-app:${{ github.ref_name }} .
    docker push docker.packages.example.com/my-app:${{ github.ref_name }}
```

| Input | Default | Description |
|---|---|---|
| `url` | *required* | Base URL of the Redskap instance (used for the token exchange) |
| `registry` | host of `url` | Registry host to log in to |
| `token` | | Already fetched token; fetched via trusted publishing if empty |
| `audience` | `url` | OIDC audience |
| `username` | `redskap` | Ignored by Redskap |

Output: `registry`. Composite actions have no post step, so the credentials stay in the runner's Docker config until the job ends. GitHub-hosted runners are discarded after the job. On self-hosted runners, add `docker logout <registry>` at the end of the job.

## upload

### Helm charts

```yaml
- run: helm package ./charts/mychart --destination dist

- uses: scheiblingco/redskap-actions/upload@v1
  with:
    url: https://packages.example.com
    repository: helm-charts
    type: helm
    files: dist/*.tgz
```

If `<chart>.tgz.prov` exists next to a chart, the action sends both through the ChartMuseum API (`POST /api/charts`). Otherwise it uses `PUT /upload`. Set `force: true` to replace an existing version with different content (otherwise Redskap returns `409`).

### Debian packages

```yaml
- uses: scheiblingco/redskap-actions/upload@v1
  with:
    url: https://packages.example.com
    repository: bookworm-main
    type: debian
    dist: bookworm
    component: main
    files: |
      dist/*.deb
      build/**/*.deb
```

### Reusing one token for several steps

```yaml
- id: redskap
  uses: scheiblingco/redskap-actions/get-token@v1
  with:
    url: https://packages.example.com

- uses: scheiblingco/redskap-actions/upload@v1
  with:
    url: https://packages.example.com
    token: ${{ steps.redskap.outputs.token }}
    repository: helm-charts
    type: helm
    files: dist/*.tgz
```

| Input | Default | Description |
|---|---|---|
| `url` | *required* | Base URL of the Redskap instance (or the repository's domain with `vhost: true`) |
| `repository` | | Redskap repository ID (not needed with `vhost: true`) |
| `type` | *required* | `helm` or `debian` |
| `files` | *required* | One path or glob per line; `**` is supported. A pattern that matches nothing fails the step |
| `token` | | Already fetched token; fetched via trusted publishing if empty |
| `audience` | `url` | OIDC audience |
| `dist` | | Debian: distribution (required for `debian`) |
| `component` | `main` | Debian: component |
| `force` | `false` | Helm: replace an existing version |
| `vhost` | `false` | `url` is the repository's own domain (vhost routing) |

Outputs: `uploaded` (JSON array of uploaded files), `count`. The action tries every file and then fails if any upload failed.

## Troubleshooting

| Error | Meaning |
|---|---|
| `No GitHub OIDC token available` | The job is missing `permissions: id-token: write` |
| `401 (G1)` | Token failed verification. Usually `audience` does not match the server's `middleware.github_actions.audience` |
| `403 (G3)` | Token is valid but no trust binding matches. The response lists the repository, ref, environment, event and workflow Redskap saw |
| `409` on a Helm upload | That chart version already exists with different content. Bump the version or set `force: true` |

## Requirements

`bash`, `curl` (7.76+) and `jq`, all preinstalled on GitHub-hosted runners; `docker` for `docker-login`.
