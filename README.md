# redskap-actions

GitHub Actions for publishing to [Redskap](https://github.com/scheiblingco/redskap) with **trusted publishing**: the workflow authenticates with its GitHub OIDC ID token, so no Redskap secret has to be stored in the repository.

| Action | What it does |
|---|---|
| [`get-token`](#get-token) | Exchanges the job's GitHub OIDC token for a short-lived Redskap token |
| [`docker-login`](#docker-login) | Logs Docker in to a Redskap OCI registry |
| [`upload`](#upload) | Uploads Helm charts and Debian packages to a Redskap repository |

All actions share two location inputs:

- `instance`: the primary URL of the Redskap instance, e.g. `https://packages.example.com`. Tokens are always fetched from here.
- `vhost` (`docker-login`, `upload`): the repository's own domain when it uses vhost routing, e.g. `docker.packages.example.com`. Leave it out for path-style repositories.

`docker-login` and `upload` fetch a token automatically unless you pass one in `token`.

## Server setup

Enable GitHub Actions auth on the Redskap instance and add a trust binding that matches your workflow:

```yaml title="config.yaml"
middleware:
  github_actions:
    enabled: true
    audience: https://packages.example.com   # the actions default `audience` to `instance`
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
    instance: https://packages.example.com
    export-env: true          # also sets $REDSKAP_TOKEN for later steps

- run: |
    curl -fsS -T dist/app.deb -H "Authorization: Bearer ${{ steps.redskap.outputs.token }}" \
      "https://packages.example.com/r/bookworm-main/debian/upload?dist=bookworm&component=main"
```

| Input | Default | Description |
|---|---|---|
| `instance` | *required* | Primary URL of the Redskap instance |
| `audience` | `instance` | OIDC audience; must match `middleware.github_actions.audience` |
| `exchange` | `true` | `false` returns the raw GitHub ID token (valid for a few minutes) instead of an exchanged Redskap token |
| `export-env` | `false` | Export the token as `REDSKAP_TOKEN` |

Outputs: `token` (masked), `expires-at`, `subject`.

## docker-login

```yaml
- uses: scheiblingco/redskap-actions/docker-login@v1
  with:
    instance: https://packages.example.com
    vhost: docker.packages.example.com   # omit for path-style routing

- run: |
    docker build -t docker.packages.example.com/my-app:${{ github.ref_name }} .
    docker push docker.packages.example.com/my-app:${{ github.ref_name }}
```

| Input | Default | Description |
|---|---|---|
| `instance` | *required* | Primary URL of the Redskap instance (used for the token exchange) |
| `vhost` | host of `instance` | The registry's vhost domain; docker logs in to this host |
| `token` | | Already fetched token; fetched via trusted publishing if empty |
| `audience` | `instance` | OIDC audience |
| `username` | `redskap` | Ignored by Redskap |

Output: `registry` (the host docker logged in to). Composite actions have no post step, so the credentials stay in the runner's Docker config until the job ends. GitHub-hosted runners are discarded after the job. On self-hosted runners, add `docker logout <registry>` at the end of the job.

## upload

### Helm charts

```yaml
- run: helm package ./charts/mychart --destination dist

- uses: scheiblingco/redskap-actions/upload@v1
  with:
    instance: https://packages.example.com
    repository: helm-charts
    type: helm
    files: dist/*.tgz
```

If `<chart>.tgz.prov` exists next to a chart, the action sends both through the ChartMuseum API (`POST /api/charts`). Otherwise it uses `PUT /upload`. Set `force: true` to replace an existing version with different content (otherwise Redskap returns `409`).

### Debian packages

```yaml
- uses: scheiblingco/redskap-actions/upload@v1
  with:
    instance: https://packages.example.com
    repository: bookworm-main
    type: debian
    dist: bookworm
    component: main
    files: |
      dist/*.deb
      build/**/*.deb
```

### Vhost repositories

`instance` stays the primary URL, because vhost domains route every path into the repository, including the token exchange endpoint. Set `vhost` to the repository's domain. A bare host uses the scheme of `instance`; a full URL is accepted too.

```yaml
- uses: scheiblingco/redskap-actions/upload@v1
  with:
    instance: https://packages.example.com
    vhost: debs.packages.example.com
    type: debian
    dist: bookworm
    files: dist/*.deb
```

### Reusing one token for several steps

```yaml
- id: redskap
  uses: scheiblingco/redskap-actions/get-token@v1
  with:
    instance: https://packages.example.com

- uses: scheiblingco/redskap-actions/upload@v1
  with:
    instance: https://packages.example.com
    token: ${{ steps.redskap.outputs.token }}
    repository: helm-charts
    type: helm
    files: dist/*.tgz
```

| Input | Default | Description |
|---|---|---|
| `instance` | *required* | Primary URL of the Redskap instance, also for vhost repositories |
| `repository` | | Redskap repository ID (not needed with `vhost`) |
| `type` | *required* | `helm` or `debian` |
| `files` | *required* | One path or glob per line; `**` is supported. A pattern that matches nothing fails the step |
| `token` | | Already fetched token; fetched via trusted publishing if empty |
| `audience` | `instance` | OIDC audience |
| `dist` | | Debian: distribution (required for `debian`) |
| `component` | `main` | Debian: component |
| `force` | `false` | Helm: replace an existing version |
| `vhost` | | The repository's vhost domain; packages are uploaded there |

Outputs: `uploaded` (JSON array of uploaded files), `count`. The action tries every file and then fails if any upload failed.

## Troubleshooting

| Error | Meaning |
|---|---|
| `No GitHub OIDC token available` | The job is missing `permissions: id-token: write` |
| `401 (G1)` | Token failed verification. Usually `audience` (default: `instance`) does not match the server's `middleware.github_actions.audience` |
| `403 (G3)` | Token is valid but no trust binding matches. The response lists the repository, ref, environment, event and workflow Redskap saw |
| `409` on a Helm upload | That chart version already exists with different content. Bump the version or set `force: true` |

## Requirements

`bash`, `curl` (7.76+) and `jq`, all preinstalled on GitHub-hosted runners; `docker` for `docker-login`.
