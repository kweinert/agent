---
name: forgejo
description: Use when working with the local forgejo instance (http://forgejo:3000), using fj or fj-ex CLI, cloning from forgejo, or managing Forgejo Actions/CI on   this environment.
---

# Local Forgejo Environment

## Host & Auth

- **Host:** `http://forgejo:3000` (resolves to `172.24.0.3` on the Docker network)
- **Token:** `FORGEJO_TOKEN` env var (HTTP Basic Auth for git operations)
- **Git clone pattern:**
  ```bash
  git clone http://forgejo:${FORGEJO_TOKEN}@forgejo:3000/{owner}/{repo}
  ```
- **In CI workflow steps** (must specify branch explicitly):
  ```yaml
  - name: Checkout
    run: |
      git clone --depth 1 \
        "http://forgejo:${FORGEJO_TOKEN}@forgejo:3000/${FORGEJO_REPOSITORY}.git" \
        --branch "${{ forgejo.ref_name }}" .
  ```

## `fj` CLI (Forgejo CLI v0.5.0)

Always pass `--host http://forgejo:3000` (explicit `http://` — it defaults to HTTPS and will fail with SSL errors).

```bash
fj --host http://forgejo:3000 <command>
```

### Common workflows

| Task | Command |
|------|---------|
| View repo | `fj repo view owner/repo` |
| Clone repo | `fj repo clone owner/repo [path]` |
| Create PR | `fj pr create --title "..." --body "..."` |
| Merge PR | `fj pr merge <number>` |
| View PR | `fj pr view <number>` |
| List issues | `fj issue search` |
| Create issue | `fj issue create --title "..." --body "..."` |
| List releases | `fj release list` |
| Create release | `fj release create --tag <tag> --title "..."` |
| List tags | `fj tag list` |
| Create tag | `fj tag create <name> <ref>` |
| Actions tasks | `fj actions tasks` |
| Actions secrets | `fj actions secrets list/create/delete` |
| Actions variables | `fj actions variables list/create/delete` |
| Dispatch workflow | `fj actions dispatch <name> <ref>` |
| Whoami | `fj whoami` |

**Auth:** `fj auth login` opens a browser (not useful headless). Use `fj auth add-key` with the `$FORGEJO_TOKEN` instead:
  ```bash
  cd /repo && echo "$FORGEJO_TOKEN" | fj auth add-key <user>
  ```

## Fetching Workflow Logs
  
Use `curl` + the Forgejo API — no special CLI tool needed.

```bash
# Get the latest run ID
RUN_ID=$(curl -sf -H "Authorization: token $FORGEJO_TOKEN" \
"http://forgejo:3000/api/v1/repos/owner/repo/actions/runs?limit=1" | \
python3 -c "import sys,json; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")

# Fetch logs (single-job workflow: job_id=0, attempt=1)
curl -sf "http://forgejo:3000/owner/repo/actions/runs/$RUN_ID/jobs/0/attempt/1/logs"
```

For multi-job workflows, iterate `job_id` (0, 1, 2...) until 404.

## CI Pipeline (Forgejo Actions)

The bfett project uses a multi-job pipeline (`.forgejo/workflows/pipeline.yml`):

| Stage | Job | Runs condition |
|-------|-----|----------------|
| **build** | `docker build -t bfett:ci-test .` | always |
| **test-bfett** | `test_package("bfett")` via tinytest | needs build |
| **test-bfett-app** | `test_package("bfett.app")` via tinytest | needs build |
| **push** | `docker push forgejo:3000/kgw-agent/bfett:<branch>` | needs test jobs + branch is `dev` or `main` |
| **deploy** | `docker run` with volume/port mounts + health checks | needs push + branch `dev` or `main` |

### Health Checks & Network Isolation

The CI runner container runs on `dev-network` (custom Docker bridge), not `--network host`.
Containers started by deploy steps without `--network dev-network` land on the default bridge
and are unreachable from the runner via `localhost:hostPort`. Always use `docker exec` to probe
the app from inside its own container:

```yaml
# ✅ Works — reaches the app via container-internal localhost
docker exec bfett-${{ ref }} curl -s -o /dev/null -w "%{http_code}" "http://localhost:3838"

# ❌ Fails — runner's localhost != host's localhost
curl -s -o /dev/null -w "%{http_code}" "http://localhost:$HOST_PORT"
```

For `docker exec` to work, the target container must have `curl` (or whatever tool) installed.

### Stale Image Cache

`docker pull <tag>` may print `Status: Image is up to date` even when the registry tag points
to a newer digest, if the runner's Docker daemon has an older copy cached. Mitigate by removing
the local tag first:

```yaml
docker rmi -f <image>:<tag> 2>/dev/null || true
docker pull <image>:<tag>
```

This forces fresh layer downloads.

- Tests are run inside the built image with:
  ```r
  library(tinytest)
  r <- test_package("bfett")
  ```
  Exits with status 1 on any failure.

- Registry push is **branch-guarded** — only `dev` and `main` get pushed. `main` also receives `:latest`.

## Git Workflow

- **Conventional commits:** `feat:`, `fix:`, `refactor:`, `doc:`, etc.
- **Push:** `git push -u origin <branch>`
- **PRs:** Use `fj pr create` (not `gh`)
- Git remote `origin` should point to `http://forgejo:3000/owner/repo`
- `fj` CLI can infer host/repo from the local git remote

## General Guidelines

### CLI-first

Before making any raw curl/API call, check if `fj` can do the job first. 

### Prefer Forgejo-native variables

Forgejo Actions provides both `FORGEJO_*` / `forgejo.*` (native) and `GITHUB_*` / `github.*` (compatibility shims) context expressions and environment variables.

**Always prefer `FORGEJO_*` / `forgejo.*` over `GITHUB_*` / `github.*` in new workflows.**

| Context expression | Env var | Purpose |
|---|---|---|
| `${{ forgejo.ref_name }}` | `$FORGEJO_REF_NAME` | Current branch or tag name |
| `${{ forgejo.repository }}` | `$FORGEJO_REPOSITORY` | `owner/repo` (e.g. `kgw-agent/bfett`) |
| `${{ forgejo.actor }}` | `$FORGEJO_ACTOR` | User who triggered the run |
| `${{ forgejo.sha }}` | `$FORGEJO_SHA` | Commit SHA that triggered the run |
| `${{ forgejo.server_url }}` | `$FORGEJO_SERVER_URL` | Forgejo instance URL |
| `${{ forgejo.workspace }}` | `$FORGEJO_WORKSPACE` | Default working directory on the runner |
| `${{ secrets.GITHUB_TOKEN }}` | `$FORGEJO_TOKEN` | Auto-generated auth token (masked in logs) |

Note: `$FORGEJO_TOKEN` is automatically masked in log output by the runner, so embedding it in URLs (e.g. `http://forgejo:${FORGEJO_TOKEN}@forgejo:3000/...`) is safe.

> **Scope limitation:** The auto-generated `$FORGEJO_TOKEN` has write permission to the **repository** (push commits, create labels, merge PRs) but **not** `write:package` scope. Container registry push requires a separate token. See [Container Registry](#container-registry) section.

## Container Registry

Forgejo has an OCI-compatible container registry at `forgejo:3000`.

> **Warning:** The auto-generated `$FORGEJO_TOKEN` has repository-level write access but **lacks `write:package` scope** (packages are owner-scoped, not repo-scoped). Using it with `docker login` will fail on push with `unauthorized: reqPackageAccess`.
> **Workaround:** Use a token with `write:package` scope stored as a secret (e.g. `REGISTRY_TOKEN`):
> ```yaml
> - name: Login to container registry
>   run: echo "${{ secrets.REGISTRY_TOKEN }}" | docker login forgejo:3000 -u <user> --password-stdin
> ```
> This applies whether you use Docker login or registry API auth.

```bash
# Get a short-lived token
TOKEN=$(curl -s "http://forgejo:3000/v2/token?service=container_registry&scope=repository:owner/repo:pull,push" \
-u "username:$FORGEJO_TOKEN" | jq -r .token)

# List tags
curl -s -H "Authorization: Bearer $TOKEN" \
"http://forgejo:3000/v2/owner/repo/tags/list"

# Docker login (for pushing)
echo "$FORGEJO_TOKEN" | docker login forgejo:3000 -u <user> --password-stdin
```

## Runner Management

```bash
# List runners registered for a repo
curl -s -H "Authorization: token $FORGEJO_TOKEN" \
"http://forgejo:3000/api/v1/repos/owner/repo/actions/runners"

# Get a runner registration token
curl -s -H "Authorization: token $FORGEJO_TOKEN" \
"http://forgejo:3000/api/v1/repos/owner/repo/actions/runners/registration-token"
```

Runners can be registered at repo, org, or instance level. Repo-level runners appear in the endpoint above; instance-level runners require `read:admin` scope.

## Environment

- **Git config:** `~/.gitconfig` has `gh` as credential helper for GitHub (not forgejo)
- **Host resolution:** `forgejo` resolves via Docker DNS, not `/etc/hosts`

