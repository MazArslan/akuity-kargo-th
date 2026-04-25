# Kargo Quickstart Template

These are the supporting files for [the Kargo Quickstart tutorial](https://docs.akuity.io/tutorials/kargo-quickstart/) in the Akuity docs.

This tutorial will walk you through a working example using Kargo with the Akuity Platform, to manage the promotion of an image from stage to stage in a declarative way.

Ultimately, you will have a Kubernetes cluster, with Applications deployed using an Argo CD control plane; and handle promotion with Kargo.


## Setup and overall design

This repo deploys a single guestbook application through three environments (`dev`, `staging`, `prod`) using Kargo for promotion orchestration and ArgoCD for the actual deployment. Both Kargo and ArgoCD run as Akuity-hosted instances — the API server, UI, and controllers live in Akuity's cloud, while a lightweight Agent for each runs in the local cluster and reconciles work back to the hosted control plane.

```
ghcr.io/mazarslan/guestbook  ──poll──▶  Warehouse  ──▶  Freight
                                                            │
                                                            ▼
                                                            ┌────────────────────────────────┐
                                                            │   Kargo (Akuity-hosted)        │
                                                            │   Stage: dev                   │
                                                            │     ↓ promote (manual)         │
                                                            │   Stage: staging               │
                                                            │     ↓ promote (manual)         │
                                                            │   Stage: prod                  │
                                                            └────────────────────────────────┘
                                                            │
                                                            │  argocd-update
                                                            ▼
                                                            ┌────────────────────────────────┐
                                                            │   ArgoCD (Akuity-hosted)       │
                                                            │   Apps → k3d cluster           │
                                                            │   guestbook-simple-{dev,       │
                                                            │            staging, prod}      │
                                                            └────────────────────────────────┘
```

The flow:

1. The Kargo `Warehouse` polls `ghcr.io/mazarslan/guestbook` every 5 minutes
   for new SemVer-tagged images.
2. When a new image is found, Kargo creates a `Freight` — an immutable,
   named bundle representing that image at a specific digest.
3. A user (or automation) promotes the Freight into the `dev` Stage. Kargo
   runs the Stage's `promotionTemplate` steps: clones the repo, runs
   `kustomize-set-image` against `app/env/dev`, commits the change to the
   `env/dev` branch, and tells ArgoCD to sync.
4. ArgoCD's `guestbook-simple-dev` Application picks up the new commit on
   `env/dev` and deploys to the local k3d cluster.
5. The same Freight is then promoted manually through `staging` and `prod`,
   each writing to its own `env/staging` and `env/prod` branch.

Repo layout:

- `app/base/` — the guestbook Kubernetes manifests (Deployment, Service)
- `app/env/{dev,staging,prod}/` — kustomize overlays per environment
- `kargo/` — Kargo CRDs (Project, Warehouse, Stages, credentials)
- `akuity/` — Akuity Platform declarative config (ArgoCD instance, Apps)
- `.devcontainer/` — Codespace bootstrap (k3d cluster, post-create scripts)
- `scripts/` — bootstrap helpers for Akuity Platform setup


## Key design decisions and

 tradeoffs

**Akuity-hosted control plane, local data plane.** 

The architecture splits Kargo and ArgoCD into a hosted API/UI and an in-cluster Agent. From a Sales
Engineer's perspective this is the most distinctive thing about the platform: customers don't have to expose their Kubernetes API to a SaaS vendor. The agent only makes outbound connections to the Akuity control plane, which is the only deployment model that will pass a security review at most regulated financial services or healthcare customers I've worked with. Tradeoff: it introduces a network dependency on the Akuity control plane, so an Akuity outage means promotions can't be triggered (though already-deployed workloads keep running, since the data plane is local).

**Single repo for app source and GitOps config.** 

The guestbook app, its kustomize overlays, the Kargo manifests, and the ArgoCD `Application` definitions all live in this repo. For a tutorial this keeps the moving parts visible. For a production setup I would split into at least two repos: one for application source, one for GitOps config (Apps, Kargo Stages, Warehouses) — so app developers don't have permission to mutate platform config and vice versa.


**Declarative credentials via Secret manifest, not CLI.** 
Instead of running `kargo create repo-credentials` imperatively, the GitHub PAT is stored in a`Secret` with the `kargo.akuity.io/cred-type: git` label. This makes the credential reproducible from the repo (with the actual token value injected at apply time, never committed). In production the next step would be ExternalSecrets Operator with a real secret backend (Vault, AWS Secrets Manager, GCP Secret Manager) so the PAT never lives in a Kubernetes Secret either.

**Manual promotion at every stage.** 
Stages are configured to require manual promotion rather than auto-flow. For a demo this surfaces the promotion mechanic clearly. For a real pipeline I would auto-promote `dev` (any new Freight goes through immediately), require manual promotion to `staging`, and add verification gates and approvals on `prod`.


## Assumptions


- The reviewer has access to the Akuity Platform org where my trial account was provisioned, and can see the Kargo and ArgoCD instances created during
  this work.
- The GitHub PAT used during the tutorial is short-lived and scoped to this repo and ghcr namespace. It is not committed to the repo.
- The guestbook image at `ghcr.io/mazarslan/guestbook` is set to public visibility so the Warehouse can read tags without image-pull credentials. In a production deployment this would be a private image with pull secrets configured.
- The Codespace devcontainer is treated as the canonical setup environment. Local-machine setups (kind, Podman, etc.) would work but are not tested
  in this submission.
- Single-cluster demo. All three environments (`dev`, `staging`, `prod`)
  deploy to the same k3d cluster, separated only by namespace. A real
  deployment would have separate clusters per environment, or at minimum
  a separate `prod` cluster.



## Changes that I have made to enhance the tutorial

### Update Kargo CLI to the latest version

#### Why 

The Codespace devcontainer ships with Kargo CLI `v0.8.7`, but the Akuity-hosted Kargo server runs `v1.10.1-ak.0`. That's a major-version gap, and it produces errors that don't point at the real cause:

- `kargo create credentials ...` → `Error: unimplemented: 404 Not Found`
- `kargo get warehouses ...` → `Error: unmarshal message: unexpected EOF`

Both look like unrelated problems (missing project, transport issue), but the actual cause is protocol drift between the old client and the new server. Some subcommands have also been renamed — `kargo create credentials` is now `kargo create repo-credentials`, for example.

Upgrading the CLI as the first setup step removes an entire class of confusing early-stage errors.

#### How

I've updated the post-start script to include the following:

```bash
arch=$(uname -m); [ "$arch" = "x86_64" ] && arch=amd64
curl -L -o /tmp/kargo "https://github.com/akuity/kargo/releases/latest/download/kargo-linux-${arch}"
chmod +x /tmp/kargo
sudo mv /tmp/kargo /usr/local/bin/kargo
hash -r
```

### Update all user names to lowercase

#### Why

My GitHub username has uppercase characters (`MazArslan`), and Docker rejects it immediately at push time:

```
ERROR: invalid reference format: repository name (MazArslan/guestbook) must be lowercase
```

The problem is that nothing downstream of Docker does the same check. Kargo's Warehouse accepts `repoURL: ghcr.io/MazArslan/guestbook` with no warning and
reports `Ready: True`. The `kustomize-set-image` promotion step then writes that uppercase reference verbatim into committed manifests on the `env/*` branches. The error only surfaces later, at Argo CD sync time, two layers removed from the original input.

By then the bad reference is in git history and in Freight metadata, so recovery isn't just "fix the source" — it requires reapplying the Warehouse, deleting the `env/*` branches, and deleting poisoned Freight.

Standardizing on lowercase from the start avoids the entire cascade.


#### How

In the post start script the env variable has been updated to lower case using:

```bash
export GITHUB_USER="${GITHUB_USER,,}"
```

### Split kargo/stages.yaml into two phased files

#### Why

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



## Tutorial drift observations

These are issues I noticed in the base tutorial that shaped my impression
of the first-time-user experience. The first three I addressed in the
Changes section above; including them here for completeness so the full
picture of tutorial drift is in one place. The rest are flagged but
unaddressed since they live in Akuity's docs rather than this repo.

**Issues I worked around:**

- **CLI version skew.** Devcontainer ships Kargo CLI `v0.8.7` against a
  `v1.10` server. Errors are cryptic (`unimplemented: 404`,
  `unexpected EOF`) and don't point at the cause. Fixed by upgrading the
  CLI as the first setup step — see Changes section.

- **Mixed-case GitHub usernames.** Tutorial doesn't normalize `GITHUB_USER`
  to lowercase before substituting it into Warehouse `repoURL` and
  kustomize image refs, even though OCI requires lowercase. The bad
  reference cascades through three layers before surfacing. Fixed by
  lowercasing in the post-create script — see Changes section.

- **Stages with `argocd-update` applied before ArgoCD is wired up.**
  Section 3 has the user apply Stages whose promotion template includes
  `argocd-update`, but Section 4 is where ArgoCD is actually linked to
  Kargo — so the first promotion fails on step 7. Fixed by splitting
  the Stage manifest into two phased files — see Changes section.

- **Dead `kargo-argocd-manifestupdate.sh` script.** The bootstrap calls a
  script that mutates Stages to inject `spec.promotionMechanisms.argoCDAppUpdates[0].appName`,
  a field from the deprecated pre-v1.0 Stage API. Fails with a 422 against
  current Kargo. Removed from the bootstrap flow — see Changes section.

**Issues left unaddressed (live in the docs, not this repo):**

- **kind vs k3d ambiguity (Section 2.1.1).** Prerequisites mention kind as
  an option, but the Codespace devcontainer creates a k3d cluster. Worth
  picking one, especially for users who already have a kind/Podman setup
  locally.

- **Classic vs fine-grained PAT not specified.** The instructions say to
  create a GitHub PAT but don't specify which type. Required scopes
  (`repo`, `write:packages`, etc.) differ between the two, and fine-grained
  PATs require explicit per-repo selection.

- **Stale screenshots and missing UI elements.** The Akuity logo and
  several UI controls have been updated since the tutorial screenshots
  were captured. The "target" promotion icon referenced in some steps
  doesn't appear in the current UI. New users searching for the
  pictured visual cue won't find it.

- **`kargo create credentials` still in the docs.** The CLI command was
  renamed to `kargo create repo-credentials` in v1.x. Tutorial still uses
  the old name, which fails against current Kargo even after a CLI
  upgrade if the user copies the command verbatim from the docs.



## Bonus considerations

The take-home brief lists several optional explorations. I didn't implement
any of these, but each shaped how I'd think about extending this setup. Brief
notes below.

### Monorepo / portfolio deployment

This repo's shape — one app, three environments, one Kargo project — works
at 1 app and breaks down past ~10. A rough evolution path:

- **~10 apps, single team:** 
one repo, per-app directories (`apps/guestbook/`,`apps/cart/`), one Kargo `Project` per app. 
ArgoCD Applications still hand-written.
- **~50 apps, multiple teams:** 
split into a config repo (Kargo + ArgoCD manifests) and N source repos. ApplicationSets generate the per-environment Applications from a list.
- **~500 apps, platform-as-a-service:** 
each app team owns a small declarative file (image repo, environments, promotion policy) that a generator templates into full Kargo + ArgoCD definitions. The bottleneck becomes the team that owns the templates, not the platform.


The cliff between the second and third model is where most platform teams get stuck — that's the conversation worth having with a customer.

### ApplicationSet use cases

ApplicationSets are useful when the same app shape repeats across slots — environments, clusters, or tenants. Cases I'd reach for:

- **Per-environment fanout** for one app, replacing hand-written dev/staging/prod Applications with a single list generator.
- **Per-cluster fanout** for platform addons (ingress, cert-manager, monitoring), using ArgoCD's Cluster generator so adding a cluster auto-deploys the addons.
- **Per-tenant fanout** in a multi-tenant platform, generating namespace + RBAC + base workloads from a tenant list.

Where they fall short: when per-slot config diverges enough that the template fills with conditionals. At that point a custom generator emitting real Application manifests is cleaner than fighting ApplicationSet's templating.

In this repo, the next ApplicationSet I'd add is per-environment fanout for the guestbook app — collapsing the three `guestbook-simple-{dev,staging,prod}` Applications into one.


### Component vs business application workloads

Platform addons (ingress, cert-manager, monitoring, log shipper) have a different deployment shape than business apps and warrant different Kargo/ArgoCD modeling:

- **Deployed once per cluster, not promoted across environments.** A cluster runs one ingress controller. Stages for components are flat (one per cluster) rather than chained (dev → staging → prod).
- **Versioned by upstream releases**, so the Warehouse subscribes to a Helm chart repo or OCI artifact, not a self-built image.
- **Gated on cluster-level health**, not app-level smoke tests. Verification is "all existing Applications still reconcile" rather than "guestbook is healthy."
- **Larger blast radius.** A bad cert-manager upgrade takes down every TLS endpoint. Canary clusters and longer soak times matter more than for business apps.

I'd model components as a separate Project (or set of Projects by category)
with cluster-keyed promotion pipelines and stricter verification.



### App-of-apps with Kargo

App-of-apps is the older ArgoCD pattern where one parent Application points at
a directory of child Application manifests. The parent owns *which apps exist*;
each child owns *deploying its workload*. ApplicationSets has largely replaced
it for new designs, but app-of-apps still fits when the children aren't a
uniform list — for example, a cluster bootstrap combining cert-manager,
ingress, monitoring, and a few hand-written platform Applications.

It composes cleanly with Kargo because the two own different axes:
app-of-apps owns set membership; Kargo owns version progression across
the environments those apps live in.

#### How I'd apply it to this repo

The parent Application would point at `main` + an `apps/` directory containing
one Application file per environment. The children would point at their
respective `env/*` branches — the same branches Kargo writes to today.

The non-obvious detail is that each child Application needs a
`kargo.akuity.io/authorized-stage: kargo-simple:<env>` annotation. That's
what authorizes Kargo's `argocd-update` promotion step to trigger syncs on
the child. Without it, Kargo can't drive a child it didn't create itself.

Migration would be: split `akuity/apps.yaml` into three files under `apps/`,
add a parent Application pointing at that directory, delete the existing
standalone Applications so the parent's children don't collide with them,
then apply the parent once. From that point Kargo promotes through the
children exactly as before — the parent stays Synced while children move.

#### Why this is a thought exercise

For 1 app and 3 environments, the refactor is cosmetic. The pattern earns
its complexity at 30+ apps where the monolithic-file problem becomes real
and per-app PRs become valuable. I scoped this as a write-up to keep the
submission focused on the Kargo-specific learnings.



## Production hardening

This submission is a tutorial-grade demo. The list below captures the changes I'd make before considering this setup production-ready. 

### Repository and branch protection

- **Branch protection on `env/*`.** 
Kargo treats `env/*` branches as generated output — each promotion runs `git-clear` and force-pushes a fresh rendered manifest. ArgoCD, however, watches those branches as input and has no way to know they're machine-only. A human who pushes directly to `env/dev` will see ArgoCD sync the change normally, until Kargo's next promotion silently wipes it on a force-push. Branch protection rules restricting pushes on `env/*` to the Kargo service account close this gap at the git layer where it belongs.

- **Split repos: app source vs GitOps config.** 
Keep the application source in one repo and the platform config (Kargo `Project` / `Warehouse` / `Stage`, ArgoCD `Application` / `ApplicationSet`) in another. Application developers shouldn't have permission to mutate the promotion pipeline, platform engineers shouldn't need to fork app repos to change a Stage definition.

### Secrets management

- **ExternalSecrets Operator + a real backend.** 

The GitHub PAT is currently stored as a plain Kubernetes `Secret`. In production this should come from Vault, AWS Secrets Manager, GCP Secret Manager, or Akeyless via ExternalSecrets — the secret never lives in a Kubernetes API object that cluster admins can read with `kubectl get secret -o yaml`.

- **Replace long-lived PATs with short-lived tokens.** 
A GitHub App with installation tokens (1-hour TTL, automatically refreshed) is preferable to a personal access token. Same story for image pull credentials — IRSA, Workload Identity, or OIDC federation, not static credentials.

### Authentication and access control

- **SSO via Dex.** 
Both Kargo and ArgoCD support SSO through Dex with the organization's identity provider as the OIDC source. The trial setup uses a shared admin account; production should enforce per-user identity so every promotion and sync is attributable.

- **RBAC tied to identity, not bearer tokens.** 
Once SSO is in place, define roles like `developer` (can promote dev/staging, read-only on prod), `release-manager` (can promote prod), `auditor` (read-only everywhere) with claims-based mapping. Akuity's RBAC docs cover this.

- **Mandatory MFA on the IdP** 
for any role that can write to `prod`.

### Pipeline safety

- **Auto-promote `dev`, gate `staging` and `prod`.** 
Currently every Stage is manual. The realistic pattern is auto-promote `dev` on every new Freight (so developers see their image deployed continuously), require
manual approval to promote into `staging` and `prod`. Kargo's `Promotion` resources can be wired to require approvals.

- **Verification steps with `analysisTemplates`.** 
Each Stage should have a verification step that runs after the deploy — smoke tests against `dev`, integration tests against `staging`, canary metrics against `prod`. Failed verification automatically marks the Freight as unverified for that Stage and blocks downstream promotion.


### Multi-cluster and isolation

- **One cluster per environment, at minimum a separate `prod` cluster.**

All three environments currently run on the same k3d cluster, separated by namespace. Production environments share a control plane with dev environments under no security model I'd defend in a customer conversation. Akuity's multi-cluster model handles this cleanly — each cluster runs its own ArgoCD Agent and Kargo Agent, both connected to the same hosted control plane.

- **Network policy and Pod Security Standards.** 
Default-deny network policies per namespace, `restricted` Pod Security Standard on `prod`.

### Observability

- **Audit logs forwarded to a long term store.** 
Akuity's audit log feature captures who promoted what, when, from where. In a regulated environment those logs need to be forwarded to a long-term store (Splunk, Datadog, CloudWatch) — Akuity's UI is fine for spot-checks but doesn't satisfy a 7-year retention requirement.

- **Prometheus metrics + alerting.** 
Both Kargo and ArgoCD export metrics. Alert on: failed promotions, Application drift, Stage health conditions flipping false, Warehouse discovery latency.

- **Drift detection on the cluster side.** 
ArgoCD's `OutOfSync` detection catches drift in cluster state vs git, but not drift on the env branches themselves. A scheduled job that re-renders manifests from `(main, current Freight)` and diffs against the env branch would catch any history rewrite or branch-protection bypass.

### Disaster recovery

- **Backup of Kargo `Project` and `Stage` definitions.** 
They live in the hosted Akuity control plane, but the source of truth should be this git repo so the entire platform config can be rebuilt from scratch.

- **Tested rollback procedure.** 
Promoting an older Freight forward is the documented rollback path, The runbook should specify how to do this under time pressure, including what to do if the older Freight's image has been garbage-collected from ghcr.

- **Runbook for control-plane outage.** 
If the Akuity hosted control plane is unreachable, already-deployed workloads keep running (data plane is local) but no promotions can happen. 
Runbook should cover communication, expected duration, and any local fallback options.