# Shared-transport fork: update instructions

This fork carries one temporary patch on top of upstream releases of
`crossplane-contrib/provider-upjet-azure`. These instructions are written so
that an agent can carry the patch over to a new upstream release on its own.

Typical prompt: *"Follow hack/SHARED-TRANSPORT.md and update the fork to
`<tag>`"* (or *"…to the latest release"*).

## What the patch is

- **Problem:** go-azure-sdk creates a new `http.Transport` for every request,
  and the provider configures a fresh azurerm client on every reconcile. Every
  ARM call opens a new TCP+TLS connection, which exhausts outbound SNAT ports
  behind an Azure Standard Load Balancer.
  Upstream: crossplane-contrib/provider-upjet-azure#1349,
  hashicorp/terraform-provider-azurerm#32986.
- **Fix:** `axiansinfoma/terraform-provider-azurerm` (a fork of
  `upbound/terraform-provider-azurerm`) adds `internal/clients/transport.go`
  and sets `Transport: sharedTransport` in `internal/clients/builder.go`.
- **This fork** only points the azurerm `replace` in `go.mod` at that commit
  and adds:
  - `.github/workflows/publish-shared-transport.yaml`: builds the
    subpackages we run (linux/amd64) and publishes them to
    `ghcr.io/axiansinfoma/provider-azure-<subpackage>:<version>`;
  - `hack/rebase-shared-transport.sh`: carries the patch to a new release;
  - this file.

There are no other code changes. Branches are named `shared-transport-<tag>`
here and `<upbound-branch>-shared-transport` in the azurerm fork. The current
provider branch is the fork's default branch, because `workflow_dispatch`
only works for workflows on the default branch.

## Hard rules

- **Never compile** azurerm or the provider locally: it exhausts the memory of
  a typical dev container. Go is only used for `gofmt`, `go mod download` and
  `go list -m`. Builds run in GitHub Actions.
- **Never rewrite pushed history:** no force-push, no amend or rebase of
  pushed commits. Create new branches or new commits instead.
- **Never open PRs, issues or comments upstream** (crossplane-contrib,
  upbound, hashicorp) unless explicitly asked.
- **Only the patch:** do not change upstream files beyond `go.mod`/`go.sum`,
  and do not touch the fix itself unless a conflict forces it.
- **Stop and report** instead of guessing on: cherry-pick/apply conflicts, a
  failing build, or any sign that the patch is no longer needed.

## Prerequisites

- Checkouts of `axiansinfoma/provider-upjet-azure` and
  `axiansinfoma/terraform-provider-azurerm` side by side (or `AZURERM_DIR` set
  to the azurerm checkout). Shallow clones are fine.
- `git`, `go`, and `gh` logged in with the `repo` and `workflow` scopes
  (`gh auth status`). Run `gh auth setup-git` if git pushes ask for
  credentials.
- Clean working trees, with the current `shared-transport-<tag>` branch
  checked out in the provider fork.

## Procedure

### 0. Pick the target and check whether the fork is still needed

```bash
gh release list --repo crossplane-contrib/provider-upjet-azure --limit 5
gh issue view 32986 --repo hashicorp/terraform-provider-azurerm --json state,closedAt
```

Read the azurerm `replace` of the target tag and check whether that commit
already shares a transport:

```bash
TAG=v2.x.y
SHA=$(gh api -H "Accept: application/vnd.github.raw" \
  "repos/crossplane-contrib/provider-upjet-azure/contents/go.mod?ref=$TAG" |
  grep '^replace github.com/hashicorp/terraform-provider-azurerm' | sed -E 's/.*-([0-9a-f]{12})$/\1/')
gh api -H "Accept: application/vnd.github.raw" \
  "repos/upbound/terraform-provider-azurerm/contents/internal/clients/builder.go?ref=$SHA" | grep -n Transport
```

Only the go-vcr line (`o.Transport = r`) means the fix is still missing:
continue. If upstream sets a transport outside go-vcr, or #32986 is closed as
fixed, **stop and report that the fork is no longer needed**. Do not build.

### 1. Local run and review

```bash
hack/rebase-shared-transport.sh "$TAG"
```

- **If the azurerm pin is unchanged,** the script creates
  `shared-transport-$TAG` locally and exits.
- **If the pin changed,** it cherry-picks the fix onto the new upbound commit
  as `<upbound-branch>-shared-transport` and stops: `go.sum` needs that commit
  on GitHub, so the provider branch is created by the `--push` run in step 2.

Review before pushing:

- **azurerm branch:** `git -C ../terraform-provider-azurerm show --stat HEAD`.
  Expect only `internal/clients/transport.go` (new) and 3–4 added lines in
  `internal/clients/builder.go`.
- **provider branch,** if created: `git diff "$TAG" --stat`. Expect only
  `go.mod` (the `replace` line), `go.sum` (two `axiansinfoma/...` lines
  replacing two `upbound/...` lines), the workflow and `hack/`.

On a conflict the script stops with a message. Resolve only if the resolution
is mechanical (e.g. the `ClientOptions` block in `builder.go` moved), then
`git cherry-pick --continue` and re-run the script. The script reuses an
existing azurerm branch. Otherwise stop and report.

### 2. Push and build

```bash
hack/rebase-shared-transport.sh "$TAG" --push --build
```

This pushes both branches, makes `shared-transport-$TAG` the fork's default
branch, disables upstream workflows that became active, and starts the
publish workflow for `$TAG-pooled.1`.

Run it from whatever step 1 left checked out: the new
`shared-transport-$TAG` branch (unchanged pin), or the old branch (changed
pin). The script reuses the prepared azurerm and provider branches.

To rebuild the same tag (e.g. after fixing the workflow), publish
`$TAG-pooled.2` and so on. Never overwrite a published version:

```bash
gh workflow run publish-shared-transport.yaml --repo axiansinfoma/provider-upjet-azure \
  --ref "shared-transport-$TAG" -f version="$TAG-pooled.2"
```

### 3. Watch the build

```bash
gh run list --repo axiansinfoma/provider-upjet-azure --workflow publish-shared-transport.yaml --limit 1
gh run watch <run-id> --repo axiansinfoma/provider-upjet-azure --exit-status
```

The build takes a while; *Build Artifacts* is the long step. On failure,
collect the failing step's log (`gh run view <run-id> --log-failed`) and stop.

### 4. Verify the packages

Every package must be anonymously pullable (clusters use no pull secret) and
must depend on the **upstream** family provider:

```bash
V="$TAG-pooled.1"
for p in authorization insights managedidentity sql storage; do
  r=axiansinfoma/provider-azure-$p
  t=$(curl -sf "https://ghcr.io/token?scope=repository:$r:pull" | jq -r .token)
  echo "$r:$V $(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $t" \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json' \
    "https://ghcr.io/v2/$r/manifests/$V")"
done
```

Expect `200` for all five. For one package, check the `base` layer's
`package.yaml`: `dependsOn` must be
`xpkg.crossplane.io/crossplane-contrib/provider-family-azure` with
`version: '>= 0.0.0-0'`.

### 5. Report

Report back with:

- target tag and version (`$TAG-pooled.1`);
- azurerm fork branch and commit, and whether the pin changed;
- provider fork branch and commit;
- workflow run URL and result;
- the five package references and the verification result.

Deploying the packages, i.e. updating the `Provider` manifests in the GitOps
repository, is a separate step. It is done there, not in this fork.

## Removing the fork

Once upstream ships the fix (step 0 says so), consumers switch back to
`xpkg.crossplane.io/crossplane-contrib/provider-azure-*`. Afterwards the
`axiansinfoma` forks can be deleted.
