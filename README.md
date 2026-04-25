# Kargo Quickstart Template

These are the supporting files for [the Kargo Quickstart tutorial](https://docs.akuity.io/tutorials/kargo-quickstart/) in the Akuity docs.

This tutorial will walk you through a working example using Kargo with the Akuity Platform, to manage the promotion of an image from stage to stage in a declarative way.

Ultimately, you will have a Kubernetes cluster, with Applications deployed using an Argo CD control plane; and handle promotion with Kargo.



## Changes that I have made to enhance the tutorial

## Update Kargo CLI to the latest version

### Why 

The Codespace devcontainer ships with Kargo CLI `v0.8.7`, but the Akuity-hosted Kargo server runs `v1.10.1-ak.0`. That's a major-version gap, and it produces errors that don't point at the real cause:

- `kargo create credentials ...` → `Error: unimplemented: 404 Not Found`
- `kargo get warehouses ...` → `Error: unmarshal message: unexpected EOF`

Both look like unrelated problems (missing project, transport issue), but the actual cause is protocol drift between the old client and the new server. Some subcommands have also been renamed — `kargo create credentials` is now
`kargo create repo-credentials`, for example.

Upgrading the CLI as the first setup step removes an entire class of confusing early-stage errors.

#### How

I've updated the post-start script to include the following
```bash
arch=$(uname -m); [ "$arch" = "x86_64" ] && arch=amd64
curl -L -o /tmp/kargo "https://github.com/akuity/kargo/releases/latest/download/kargo-linux-${arch}"
chmod +x /tmp/kargo
sudo mv /tmp/kargo /usr/local/bin/kargo
hash -r
```

## Update all user names to lower case

#### Why

My GitHub username has uppercase characters (`MazArslan`), and Docker rejects it immediately at push time:

ERROR: invalid reference format: repository name (MazArslan/guestbook) must be lowercase

The problem is that nothing downstream of Docker does the same check. Kargo's Warehouse accepts `repoURL: ghcr.io/MazArslan/guestbook` with no warning and
reports `Ready: True`. The `kustomize-set-image` promotion step then writes that uppercase reference verbatim into committed manifests on the `stage/*` branches. The error only surfaces later, at Argo CD sync time, two layers removed from the original input.

By then the bad reference is in git history and in Freight metadata, so recovery isn't just "fix the source" — it requires reapplying the Warehouse, deleting the `stage/*` branches, and deleting poisoned Freight.

Standardizing on lowercase from the start avoids the entire cascade.

#### How

In the post start script the env variable has been updated to lower case using

```bash
export GITHUB_USER="${GITHUB_USER,,}"
```

## Split kargo/stages.yaml into two phased files

### Why

The base tutorial's `kargo/stages.yaml` includes the `argocd-update` step on every Stage from the start. The tutorial then walks you through Section 3
(Kargo-only setup) before Section 4 introduces ArgoCD and links it to the Kargo instance.

The result is that the first promotion attempted in Section 3 fails on the `argocd-update` step: 

```
step "step-7" met error threshold of 1: error running step "step-7": Argo CD integration is disabled on this controller; cannot update Argo CD Application resources
```

Because Kargo Stages depend on upstream Stages (`staging` reads from `dev`, `prod` reads from `staging`), one failed Stage cascades — promotions can't flow through the pipeline at all until ArgoCD is wired up.

Splitting the manifest into two files lets the user apply only the non-ArgoCD steps in Section 3, see Kargo work in isolation (promotions update `env/*` branches via pure git manipulation), then layer the ArgoCD integration on top in Section 4.

#### How

I duplicated `kargo/stages.yaml` and split it into two:

- `kargo/stages.yaml` — Stages without `argocd-update`. Used in Section 3.
- `kargo/stages-argo.yaml` — same Stages with the `argocd-update` step appended. Applied in Section 4.3.2 after the ArgoCD instance is created and linked to Kargo.

Applying `stages-argo.yaml` over the existing Stages updates them in place rather than creating new ones — the `metadata.name` and `namespace` match, so it's a server-side merge.

I also removed the call to `bash scripts/kargo-argocd-manifestupdate.sh` from the bootstrap flow. That script was patching Stages to inject a field (`spec.promotionMechanisms.argoCDAppUpdates[0].appName`) from the deprecated pre-v1.0 Stage API. The modern step-based Stage API encodes the app name directly in the `argocd-update` step's `apps[].name` field, so the patch script is unnecessary and produces a 422 error against current Kargo versions.