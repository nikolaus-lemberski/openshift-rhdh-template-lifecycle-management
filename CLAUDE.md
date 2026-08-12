# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A demo of automated Software Template lifecycle management in Red Hat Developer Hub (RHDH): when a platform
engineer updates a Backstage Software Template's skeleton (e.g. bumping the Quarkus version), the change is
automatically proposed as GitLab merge requests to every downstream repo that was scaffolded from that template.

There is no application code to build/test here — this is a Backstage template (`templates/quarkus-app/`) plus a
set of bash scripts (`scripts/`) that configure an already-provisioned OpenShift/RHDH/GitLab cluster and drive the
demo. There is no CI, linter, or test suite; "running" this repo means executing the shell scripts against a live
cluster.

## Repo layout

- `templates/quarkus-app/template.yaml` — the Backstage `Template` entity (parameters + scaffolder steps). Carries
  the lifecycle-tracking version in `metadata.annotations["backstage.io/template-version"]`.
- `templates/quarkus-app/skeleton/` — the actual Quarkus project files that get scaffolded into new app repos
  (fetched by the `fetch:template` step). `skeleton/catalog-info.yaml` links every scaffolded entity back to the
  template via `spec.scaffoldedFrom: template:default/quarkus-app` — this is the other half of the lifecycle wiring.
- `templates/quarkus-app/manifests/` — Helm charts for the GitOps repo: `app/` (the deployed Quarkus app: Deployment,
  Service, Route, HPA) and `build/` (Tekton pipeline: git-clone → maven-build → buildah build/push → ACS scan → SBOM
  generation → rollout-restart, wired to a GitLab webhook via an EventListener/TriggerBinding/TriggerTemplate).
- `scripts/` — bash automation, run in this order for the "plugin" workflow, or with the diff-scoping variant, see
  below:
  - `push-template.sh` — auto-detects cluster values from the OpenShift API, replaces `__PLACEHOLDER__` markers in
    the template, and commits it into the `rhdh/rhdh-templates` GitLab repo via GitLab's Commits API. Re-run this
    any time the template/skeleton changes.
  - `enable-template-lifecycle.sh` — enables the `scaffolder-relation-processor` dynamic plugin and
    `scaffolder.pullRequests.templateUpdate` / `notifications.templateUpdate` in RHDH's `app-config-rhdh` ConfigMap,
    adds ArgoCD `ignoreDifferences` so GitOps doesn't revert the change, restarts RHDH, and verifies the plugin
    actually loaded.
  - `disable-automated-lifecycle.sh` — flips `scaffolder.pullRequests.templateUpdate.enabled` back to `false` (used
    when switching to the scoped-diff alternative below); leaves the plugin and notifications enabled since scoped
    diffing still depends on the `scaffoldedFrom` catalog relations it maintains.
  - `propagate-skeleton-diff.sh` — alternative, on-demand lifecycle propagation. Diffs the last two commits pushed
    to `rhdh/rhdh-templates` (via GitLab's compare API, scoped to `templates/<template>/skeleton`), finds all repos
    scaffolded from the template via the RHDH catalog API, and opens an MR per repo where that scoped patch applies
    cleanly (`git apply`) — skipping and reporting repos where it doesn't, rather than doing a noisy full-repo diff.
    Needs `RHDH_TOKEN` on clusters without guest auth (see README for how to source it from RHDH's own
    `backend.auth.externalAccess` secret).

Every script supports `--dry-run` and reads cluster values from env vars with auto-detected defaults (GitLab host,
Quay host, cluster subdomain, GitOps namespace, GitLab token) — see the README's variable tables rather than
duplicating them here.

## Architecture: how the lifecycle tracking actually works

Two fields connect a scaffolded repo back to its template so the `scaffolder-relation-processor` plugin can find it:

1. `template.yaml`'s `backstage.io/template-version` annotation — bumping this is the trigger.
2. `skeleton/catalog-info.yaml`'s `spec.scaffoldedFrom: template:default/quarkus-app` — makes every scaffolded
   entity queryable back to its source template; `catalog:register` sets `backstage.io/managed-by-location`
   pointing at the entity's own repo.

When the version increases, the plugin (Part 2 workflow) or `propagate-skeleton-diff.sh` (Part 3, scoped
alternative) finds all entities with that `scaffoldedFrom` relation and proposes changes:

- **Part 2 (plugin's built-in behavior)**: diffs the *entire current* skeleton against the *entire current* state of
  each downstream repo. Simple but noisy — a project's own unrelated edits to skeleton-tracked files show up in the
  MR too, since there's no upstream config option to scope this.
- **Part 3 (`propagate-skeleton-diff.sh`)**: diffs only the last two template-repo commits (scoped to the skeleton
  path) and applies that exact patch per downstream repo, skipping repos where it doesn't apply cleanly. Uses
  GitLab's already-pushed commit history as the diff baseline (not local git tags), since `push-template.sh` pushes
  from whatever is on disk — a local tag could silently point at the wrong commit if a skeleton edit wasn't
  committed first, whereas GitLab's history is written exactly once per `push-template.sh` run.

Known limitations of both paths (see README "Caveats" and "Trade-offs" for the full list): the plugin's variable
resync uses regex matching on `${{ values.* }}` and strips Jinja2 `{% if %}` blocks; the scoped-diff script does no
variable substitution at all, so a patch touching a `${{ values.* }}` line in the skeleton will likely fail to apply
downstream (and gets reported as skipped, not silently corrupted). **Always review generated MRs before merging.**

The plugin detects version changes only relative to a *cached* baseline seeded the first time it processes the
template entity — if a version bump is pushed before the plugin is enabled/restarted, that transition is recorded
as the new baseline silently, with no MR. The README's troubleshooting section walks through recovering from this
(bump again to get a live transition) and other failure points (plugin not loaded, GitLab token/permissions,
`managed-by-location` not being a `url:` location).

## Working on this repo

- Treat `templates/quarkus-app/skeleton/` as the source of truth for what gets scaffolded into new app repos —
  changes there are what `propagate-skeleton-diff.sh` and the plugin will eventually diff and MR downstream.
  `templates/quarkus-app/skeleton/target/` is stale Maven build output checked into the skeleton by accident; don't
  treat it as template source.
- Any skeleton change intended to roll out to existing apps must be paired with bumping
  `metadata.annotations["backstage.io/template-version"]` in `template.yaml` — without that bump, nothing downstream
  will ever see the change.
- `__GITLAB_HOST__`, `__CLUSTER_SUBDOMAIN__`, `__QUAY_HOST__`, `__GITOPS_NAMESPACE__` in `template.yaml` are
  placeholders substituted by `push-template.sh` at push time from live cluster values — don't hardcode real
  hostnames into the template.
- There's no automated test harness; validating a change means running the scripts against a real
  OpenShift+RHDH+GitLab cluster and following the README's Part 2/Part 3 walkthroughs end to end.
