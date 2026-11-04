#!/usr/bin/env bash
# Carries the shared-transport patch (crossplane-contrib/provider-upjet-azure#1349)
# over to a new upstream release of provider-upjet-azure.
#
# Usage:
#   hack/rebase-shared-transport.sh <new-tag> [--push] [--build]
#
# Run it from a checkout of axiansinfoma/provider-upjet-azure that has the
# current shared-transport-<tag> branch checked out. AZURERM_DIR must point at
# a checkout of axiansinfoma/terraform-provider-azurerm.
#
# Without flags everything stays local. --push pushes both branches, makes the
# new provider branch the fork's default branch (workflow_dispatch needs the
# workflow there) and disables newly added upstream workflows. --build (needs
# --push) starts "Publish shared-transport packages" for <new-tag>-pooled.1.
#
# Requires git, gh (logged in, with the workflow scope for --push) and go.
# Nothing is compiled: go is only used for gofmt and to download the replaced
# module for go.sum.
set -euo pipefail

FORK_ORG=axiansinfoma
PROVIDER_REPO="$FORK_ORG/provider-upjet-azure"
AZURERM_REPO="$FORK_ORG/terraform-provider-azurerm"
UPSTREAM_PROVIDER=crossplane-contrib/provider-upjet-azure
UPSTREAM_AZURERM=upbound/terraform-provider-azurerm
TF_MODULE=github.com/hashicorp/terraform-provider-azurerm
WORKFLOW_FILE=.github/workflows/publish-shared-transport.yaml
SUBPACKAGES="authorization insights managedidentity sql storage"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }

NEW_TAG=""; PUSH=false; BUILD=false
for arg in "$@"; do
  case "$arg" in
    --push) PUSH=true ;;
    --build) BUILD=true ;;
    -*) die "unknown flag $arg" ;;
    *) [ -z "$NEW_TAG" ] && NEW_TAG=$arg || die "unexpected argument $arg" ;;
  esac
done
[ -n "$NEW_TAG" ] || die "usage: $0 <new-tag> [--push] [--build]"
$BUILD && ! $PUSH && die "--build needs --push"

PROVIDER_DIR=$(git rev-parse --show-toplevel)
AZURERM_DIR=${AZURERM_DIR:-$(dirname "$PROVIDER_DIR")/terraform-provider-azurerm}
[ -d "$AZURERM_DIR/.git" ] || die "AZURERM_DIR=$AZURERM_DIR is not a git checkout"
if [ -x /home/vscode/volume/.tools/go/bin/go ]; then
  export PATH=/home/vscode/volume/.tools/go/bin:$PATH
fi
command -v go >/dev/null || die "go not found"

# pseudo_version_sha <go.mod content>: the commit (12 chars) the azurerm replace pins.
replace_line() { grep -E "^replace $TF_MODULE => " ; }
pinned_sha() { replace_line | sed -E 's/.*-([0-9a-f]{12})$/\1/'; }
pinned_module() { replace_line | awk '{print $4}'; }

ensure_remote() { # <dir> <name> <repo>
  git -C "$1" remote get-url "$2" >/dev/null 2>&1 || git -C "$1" remote add "$2" "https://github.com/$3.git"
}

for d in "$PROVIDER_DIR" "$AZURERM_DIR"; do
  [ -z "$(git -C "$d" status --porcelain --untracked-files=no)" ] || die "$d has uncommitted changes"
done

# --- current state -----------------------------------------------------------
CUR_BRANCH=$(git -C "$PROVIDER_DIR" branch --show-current)
case "$CUR_BRANCH" in
  shared-transport-v*) OLD_TAG=${CUR_BRANCH#shared-transport-} ;;
  *) die "check out the current shared-transport-<tag> branch first (on $CUR_BRANCH)" ;;
esac
NEW_BRANCH="shared-transport-$NEW_TAG"
git -C "$PROVIDER_DIR" show-ref --quiet "refs/heads/$NEW_BRANCH" && die "branch $NEW_BRANCH already exists"

ensure_remote "$PROVIDER_DIR" upstream "$UPSTREAM_PROVIDER"
ensure_remote "$AZURERM_DIR" upbound "$UPSTREAM_AZURERM"
log "fetching $OLD_TAG and $NEW_TAG from $UPSTREAM_PROVIDER"
git -C "$PROVIDER_DIR" fetch -q --depth 1 upstream tag "$OLD_TAG" tag "$NEW_TAG"

OLD_UPBOUND=$(git -C "$PROVIDER_DIR" show "$OLD_TAG:go.mod" | pinned_sha)
NEW_UPBOUND=$(git -C "$PROVIDER_DIR" show "$NEW_TAG:go.mod" | pinned_sha)
[ "$(git -C "$PROVIDER_DIR" show "$NEW_TAG:go.mod" | pinned_module)" = "github.com/upbound/terraform-provider-azurerm" ] \
  || die "$NEW_TAG does not replace azurerm with upbound's fork; check whether the patch is still needed"
OUR_AZURERM=$(git -C "$PROVIDER_DIR" show HEAD:go.mod | pinned_sha)
log "azurerm: $OLD_TAG pins $OLD_UPBOUND, $NEW_TAG pins $NEW_UPBOUND, our fix is $OUR_AZURERM"

# --- 1. azurerm fork -----------------------------------------------------------
if [ "$NEW_UPBOUND" = "$OLD_UPBOUND" ]; then
  log "azurerm pin unchanged, reusing $OUR_AZURERM"
  NEW_AZURERM_FULL=$(gh api "repos/$AZURERM_REPO/commits/$OUR_AZURERM" --jq .sha)
  AZURERM_BRANCH=""
else
  NEW_UPBOUND_FULL=$(gh api "repos/$UPSTREAM_AZURERM/commits/$NEW_UPBOUND" --jq .sha)
  OLD_UPBOUND_FULL=$(gh api "repos/$UPSTREAM_AZURERM/commits/$OLD_UPBOUND" --jq .sha)
  OUR_AZURERM_FULL=$(gh api "repos/$AZURERM_REPO/commits/$OUR_AZURERM" --jq .sha)
  UPBOUND_BRANCH=$(gh api "repos/$UPSTREAM_AZURERM/commits/$NEW_UPBOUND_FULL/branches-where-head" --jq '.[0].name // empty')
  AZURERM_BRANCH="${UPBOUND_BRANCH:-upbound-$NEW_UPBOUND}-shared-transport"
  git -C "$AZURERM_DIR" fetch -q --depth 1 upbound "$NEW_UPBOUND_FULL"

  if git -C "$AZURERM_DIR" show-ref --quiet "refs/heads/$AZURERM_BRANCH"; then
    # Prepared by an earlier (local or conflicted) run: reuse it.
    git -C "$AZURERM_DIR" merge-base --is-ancestor "$NEW_UPBOUND_FULL" "$AZURERM_BRANCH" \
      || die "azurerm branch $AZURERM_BRANCH exists but is not based on $NEW_UPBOUND"
    log "azurerm: reusing existing branch $AZURERM_BRANCH"
  else
    log "azurerm: cherry-picking $OLD_UPBOUND..$OUR_AZURERM onto $NEW_UPBOUND as $AZURERM_BRANCH"
    git -C "$AZURERM_DIR" fetch -q --depth 20 upbound "$OLD_UPBOUND_FULL"
    git -C "$AZURERM_DIR" fetch -q --depth 20 origin "$OUR_AZURERM_FULL"
    git -C "$AZURERM_DIR" switch -q -c "$AZURERM_BRANCH" "$NEW_UPBOUND_FULL"
    git -C "$AZURERM_DIR" cherry-pick -s "$OLD_UPBOUND_FULL..$OUR_AZURERM_FULL" \
      || die "cherry-pick conflicts in $AZURERM_DIR: resolve, 'git cherry-pick --continue', then re-run"
  fi
  bad=$(cd "$AZURERM_DIR" && git checkout -q "$AZURERM_BRANCH" && gofmt -l internal/clients)
  [ -z "$bad" ] || die "gofmt reports: $bad"
  NEW_AZURERM_FULL=$(git -C "$AZURERM_DIR" rev-parse "$AZURERM_BRANCH")
  if ! $PUSH; then
    # go.sum needs the commit on GitHub, so the provider step waits for --push.
    log "azurerm branch $AZURERM_BRANCH prepared locally ($(git -C "$AZURERM_DIR" rev-parse --short "$NEW_AZURERM_FULL"))."
    log "Review it, then re-run with --push to push it and create $NEW_BRANCH."
    exit 0
  fi
  git -C "$AZURERM_DIR" push -q -u origin "$AZURERM_BRANCH"
fi
TS=$(TZ=UTC git -C "$AZURERM_DIR" log -1 --format=%cd --date=format-local:%Y%m%d%H%M%S "$NEW_AZURERM_FULL" 2>/dev/null \
  || gh api "repos/$AZURERM_REPO/commits/$NEW_AZURERM_FULL" --jq '.commit.committer.date' | sed -E 's/[-:TZ]//g')
PSEUDO="v0.0.0-$TS-${NEW_AZURERM_FULL:0:12}"
log "azurerm pseudo-version: $PSEUDO"

# --- 2. provider fork ----------------------------------------------------------
log "provider: creating $NEW_BRANCH from $NEW_TAG"
# All patch commits are squashed into one, using the first one's message.
FIRST_PATCH=$(git -C "$PROVIDER_DIR" rev-list --reverse "$OLD_TAG..$CUR_BRANCH" | head -1)
[ -n "$FIRST_PATCH" ] || die "no patch commits between $OLD_TAG and $CUR_BRANCH"
OLD_MSG=$(git -C "$PROVIDER_DIR" log -1 --format=%B "$FIRST_PATCH" | sed '/^Signed-off-by:/d')
git -C "$PROVIDER_DIR" switch -q -c "$NEW_BRANCH" "$NEW_TAG"
# Carry over everything except the dependency pins, which are rebuilt below.
git -C "$PROVIDER_DIR" diff "$OLD_TAG" "$CUR_BRANCH" -- . ':!go.mod' ':!go.sum' | git -C "$PROVIDER_DIR" apply --index --3way \
  || die "patch does not apply on $NEW_TAG; resolve in $PROVIDER_DIR and commit by hand"
( cd "$PROVIDER_DIR"
  sed -i -E "s#^replace $TF_MODULE => .*#replace $TF_MODULE => github.com/$AZURERM_REPO $PSEUDO#" go.mod
  sed -i '/^github.com\/upbound\/terraform-provider-azurerm /d' go.sum
  GOFLAGS=-mod=mod nice -n 10 go mod download "$TF_MODULE"
  GOFLAGS=-mod=readonly go list -m "$TF_MODULE" >/dev/null
  git add go.mod go.sum
  git commit -q -s -m "$OLD_MSG" -m "Carried over to $NEW_TAG by hack/rebase-shared-transport.sh."
)
log "provider: committed $(git -C "$PROVIDER_DIR" rev-parse --short HEAD) on $NEW_BRANCH"

if ! $PUSH; then
  log "done (local only). Review both branches, then re-run with --push --build or push by hand."
  exit 0
fi

# --- 3. push, default branch, workflows, build ---------------------------------
git -C "$PROVIDER_DIR" push -q -u origin "$NEW_BRANCH"
gh api -X PATCH "repos/$PROVIDER_REPO" -f default_branch="$NEW_BRANCH" >/dev/null
log "provider: $NEW_BRANCH is now the default branch"
sleep 5
gh api "repos/$PROVIDER_REPO/actions/workflows?per_page=100" \
  --jq ".workflows[] | select(.state == \"active\" and .path != \"$WORKFLOW_FILE\") | .id" |
  while read -r id; do gh workflow disable "$id" --repo "$PROVIDER_REPO"; done
log "provider: upstream workflows disabled"

if $BUILD; then
  gh workflow run "$(basename "$WORKFLOW_FILE")" --repo "$PROVIDER_REPO" --ref "$NEW_BRANCH" \
    -f version="$NEW_TAG-pooled.1" -f subpackages="$SUBPACKAGES"
  log "build started for $NEW_TAG-pooled.1: gh run list --repo $PROVIDER_REPO --workflow $(basename "$WORKFLOW_FILE")"
fi
