# Automated Software Template Lifecycle Management

Demonstrate how a platform team can maintain compliance and consistency across all applications created from a Software Template in Red Hat Developer Hub (RHDH). When the template skeleton changes, those changes are automatically proposed as GitLab merge requests to every downstream repository.

## Demo environment

Setup from Demo catalog: [OpenShift Advanced App Platform Demo](https://catalog.demo.redhat.com/catalog/babylon-catalog-prod?item=babylon-catalog-prod/published.ocp4-adv-app-platform-demo.prod)

## Overview

A platform engineer publishes a Python Flask Software Template. Developers create applications from it through the RHDH self-service catalog. Later, the platform engineer updates the skeleton (e.g. a security patch to the Containerfile, a new health endpoint). The `scaffolder-relation-processor` plugin detects the version bump, compares the skeleton against every downstream repo, and opens a merge request with the differences.

```
Platform Engineer                            Developer
      |                                          |
      |  1. Push template + enable lifecycle     |
      |                                          |
      |                              2. Create app from template
      |                              3. Pipeline runs, app deploys
      |                              4. Develop (push, iterate)
      |                                          |
      |  5. Update skeleton, bump version        |
      |  6. Push updated template                |
      |                                          |
      |                              7. MR appears in app repo
      |                              8. Review and merge
```



## How it works

Two fields wire up the lifecycle tracking:

`template.yaml` carries a version annotation:

```yaml
metadata:
  annotations:
    backstage.io/template-version: "1.0.0"
```

`skeleton/catalog-info.yaml` links each created entity back to its source template:

```yaml
spec:
  scaffoldedFrom: template:default/python-flask-app
```

When the template version changes, the `scaffolder-relation-processor` plugin:

1. Finds all catalog entities whose `spec.scaffoldedFrom` references this template
2. Resolves each entity's source repository via the `backstage.io/managed-by-location` annotation (set automatically by the `catalog:register` step)
3. Compares the current skeleton files against the repo contents
4. Creates a GitLab merge request with additions, modifications, and deletions

---



## Part 1 — Infrastructure Setup



### Prerequisites

- `oc` CLI logged in to the OpenShift cluster as admin
- The cluster has been provisioned with RHDH, GitLab CE, OpenShift Pipelines (Tekton), and OpenShift GitOps (ArgoCD)
- The `rhdh/rhdh-templates` GitLab repo exists (created by the cluster bootstrap)
- The `app-deployer` Helm chart is published in the GitLab Package Registry (`rhdh/helm-charts`)
- `python3` and `curl` available locally



### 1. Push the template to GitLab

The script auto-detects cluster-specific values from the OpenShift API and replaces the `__PLACEHOLDER__` markers in the template files before committing them to GitLab.

```bash
./scripts/push-template.sh              # auto-detect everything
./scripts/push-template.sh --dry-run    # preview without pushing
```

What the script does:

- Reads the cluster subdomain from `oc get ingresses.config.openshift.io cluster`
- Retrieves the GitLab root token from the `root-user-personal-token` secret
- Disables GitLab Auto DevOps at the instance level
- Replaces placeholders and commits all template files via the GitLab Commits API
- Registers the template in the root `catalog-info.yaml` if not already present

Override auto-detected values if needed:

```bash
GITLAB_HOST=my-gitlab.example.com \
CLUSTER_SUBDOMAIN=apps.my-cluster.example.com \
QUAY_HOST=quay.my-cluster.example.com \
GITOPS_NAMESPACE=rhdh-gitops \
GITLAB_TOKEN=glpat-xxxxxxxxxxxx \
./scripts/push-template.sh
```


| Variable            | Default (auto-detected)                                      |
| ------------------- | ------------------------------------------------------------ |
| `CLUSTER_SUBDOMAIN` | From `oc get ingresses.config.openshift.io cluster`          |
| `GITLAB_HOST`       | `gitlab-gitlab.<CLUSTER_SUBDOMAIN>`                          |
| `QUAY_HOST`         | `quay.<CLUSTER_SUBDOMAIN>`                                   |
| `GITOPS_NAMESPACE`  | `rhdh-gitops`                                                |
| `CHART_REPO_URL`    | GitLab Package Registry URL for the `app-deployer` chart     |
| `GITLAB_TOKEN`      | From `root-user-personal-token` secret in `gitlab` namespace |




### 2. Enable automated template lifecycle management

```bash
./scripts/enable-template-lifecycle.sh              # configure RHDH
./scripts/enable-template-lifecycle.sh --dry-run     # preview changes
```

The script configures three things on the cluster:

1. **Enables the plugin** — adds `backstage-community-plugin-catalog-backend-module-scaffolder-relation-processor-dynamic` (bundled but disabled by default) to the `dynamic-plugins` ConfigMap
2. **Enables PR creation and notifications** — adds the following to the `app-config-rhdh` ConfigMap:
  ```yaml
   scaffolder:
     pullRequests:
       templateUpdate:
         enabled: true
     notifications:
       templateUpdate:
         enabled: true
  ```
3. **Prevents ArgoCD from reverting the changes** — if RHDH is managed by an ArgoCD Application, the script adds `ignoreDifferences` entries for both ConfigMaps so GitOps sync doesn't overwrite them
4. **Restarts RHDH** and verifies the plugin loaded


| Variable           | Default                     |
| ------------------ | --------------------------- |
| `RHDH_NAMESPACE`   | `rhdh`                      |
| `ARGOCD_APP_NAME`  | `developer-hub-application` |
| `ARGOCD_NAMESPACE` | `openshift-gitops`          |




### 3. Verify in Developer Hub

Open RHDH at `https://backstage-developer-hub-rhdh.<CLUSTER_SUBDOMAIN>` and navigate to **Create** in the sidebar. The "Python Flask Application" template should appear after the catalog refreshes (~5 minutes).

---



## Part 2 — Demo Walkthrough



### Step 1: Create an application from the template

1. Open Developer Hub and go to **Create**
2. Select the **Python Flask Application** template
3. Fill in:
  - **Application Name**: e.g. `my-flask-app`
  - **Owner**: select a group from the catalog
  - **Image Organization**: leave as `parasol` (or your Quay org)
4. Click **Create**

The template scaffolds two GitLab repositories and bootstraps ArgoCD:


| What             | Where                         |
| ---------------- | ----------------------------- |
| Source code      | `parasol/my-flask-app`        |
| GitOps manifests | `parasol/my-flask-app-gitops` |
| ArgoCD apps      | `rhdh-gitops` namespace       |




### Step 2: Watch the pipeline and deployment succeed

The Tekton pipeline triggers automatically on the initial push:

```
git-clone -> buildah build+push -> ACS scan -> SBOM generation -> rollout-restart
```

Check progress in Developer Hub under the component's **CI** tab (Tekton plugin), or directly:

```bash
oc get pipelineruns -n my-flask-app-build
```

Once the pipeline completes, ArgoCD deploys the app to the dev namespace:

```bash
oc get pods -n my-flask-app-dev
curl https://my-flask-app-my-flask-app-dev.<CLUSTER_SUBDOMAIN>/hello
# {"message":"Hello from Flask!"}
```



### Step 3: Verify lifecycle tracking is wired up

Confirm the scaffolded app's `catalog-info.yaml` in GitLab (`parasol/my-flask-app`) contains:

```yaml
spec:
  scaffoldedFrom: template:default/python-flask-app
```

In Developer Hub, the component's relations should show a `scaffoldedFrom` link back to the template.

### Step 4: Update the template skeleton

Suppose a vulnerability is found in the Python 3.12 base image and all applications must move to Python 3.14. Update the Containerfile in the skeleton:

```dockerfile
# was: registry.access.redhat.com/ubi9/python-312:latest
FROM registry.access.redhat.com/ubi9/python-314:latest
```

Then bump the template version in `templates/python-app/template.yaml`:

```yaml
metadata:
  annotations:
    backstage.io/template-version: "1.1.0"  # was "1.0.0"
```



### Step 5: Push the updated template

```bash
./scripts/push-template.sh
```



### Step 6: Check for the merge request

Wait ~5 minutes for the RHDH catalog to refresh and the plugin to detect the version change. Then check GitLab for a merge request in `parasol/my-flask-app` named something like:

```
my-flask-app/template-upgrade-v1.1.0
```

The MR contains the diff between the old and new skeleton files. Review it and merge to apply the update.

If notifications are enabled, the entity owner also receives a notification in Developer Hub with a link to the MR.

### Caveats

- The sync engine uses regex matching for template variables (`${{ values.name }}`). Variables that don't match keys in the scaffolded repo remain in raw template syntax. **Always review the generated MRs before merging.**
- Conditional Jinja2 blocks (`{% if %}`) are stripped, which might cause unexpected formatting.
- If the entity owner is a Group (not a User), the MR is created without an assigned reviewer.
- The `notifications` plugin must be enabled for notifications to work (it is enabled by default on clusters provisioned with the orchestrator).

---



## Template Details



### Python Flask Application (`templates/python-app/`)

**What the template creates when a developer uses it:**

1. **Source repository** in GitLab (`parasol/<app-name>`) containing:
  - A Flask application with health check (`/`) and hello endpoint (`/hello`)
  - `Containerfile` based on UBI9 Python 3.12 with Gunicorn
  - `catalog-info.yaml` with `spec.scaffoldedFrom` for lifecycle tracking
2. **GitOps repository** in GitLab (`parasol/<app-name>-gitops`) containing:
  - ArgoCD Application definitions (dev deployment + build pipeline)
  - Helm chart for app deployment (wraps the shared `app-deployer` chart)
  - Self-contained Helm chart for the Tekton build pipeline
3. **ArgoCD Applications** in the `rhdh-gitops` namespace that sync and deploy everything

**Template parameters:**


| Parameter           | Description                           | Default   |
| ------------------- | ------------------------------------- | --------- |
| `name`              | Application name (lowercase, hyphens) | required  |
| `owner`             | Owning group (picked from catalog)    | required  |
| `description`       | Short description for the catalog     | optional  |
| `imageOrganization` | Quay organization                     | `parasol` |


**Build pipeline flow (Tekton):**

```
git push --> GitLab webhook --> EventListener --> Pipeline:
  clone-source -> buildah build+push -> ACS scan -> SBOM -> rollout-restart
```

Production promotion is triggered by git tags, which retag the image and open a merge request to update the prod values.

### Placeholders

The local template files use these placeholders which `push-template.sh` replaces at deploy time:


| Placeholder             | Replaced with                                          |
| ----------------------- | ------------------------------------------------------ |
| `__GITLAB_HOST__`       | GitLab route hostname                                  |
| `__CLUSTER_SUBDOMAIN__` | OpenShift apps subdomain                               |
| `__QUAY_HOST__`         | Quay route hostname                                    |
| `__GITOPS_NAMESPACE__`  | ArgoCD namespace (default: `rhdh-gitops`)              |
| `__CHART_REPO_URL__`    | Helm chart repository URL for the `app-deployer` chart |


---



## Project Structure

```
.
├── README.md
├── catalog-info.yaml                              # Backstage Location entity (for local reference)
├── scripts/
│   ├── push-template.sh                           # Push template to GitLab on a fresh cluster
│   └── enable-template-lifecycle.sh               # Enable automated template lifecycle management
└── templates/
    └── python-app/
        ├── template.yaml                          # Backstage scaffolder definition (versioned)
        ├── skeleton/                              # App source code skeleton
        │   ├── app.py                             # Flask app
        │   ├── requirements.txt                   # Python dependencies
        │   ├── Containerfile                      # Container build (UBI9 Python 3.12)
        │   ├── catalog-info.yaml                  # Backstage component (with scaffoldedFrom)
        │   └── .gitignore
        └── manifests/                             # GitOps manifests skeleton
            ├── argocd/
            │   ├── app-dev.yaml                   # ArgoCD Application for dev
            │   └── build.yaml                     # ArgoCD Application for build
            ├── app/
            │   ├── Chart.yaml                     # Depends on app-deployer chart
            │   └── values/
            │       ├── values-dev.yaml            # Dev: 1 replica, route enabled
            │       └── values-prod.yaml           # Prod: 2 replicas, HPA enabled
            └── build/
                ├── Chart.yaml                     # Standalone chart (no dependencies)
                ├── values.yaml                    # Pipeline configuration
                └── templates/                     # Hand-crafted Helm templates
                    ├── _helpers.tpl
                    ├── namespace.yaml
                    ├── pipeline-sa.yaml
                    ├── pipeline.yaml              # Tekton push pipeline
                    ├── pipeline-promote.yaml      # Tekton tag-promote pipeline
                    ├── event-listener.yaml
                    ├── event-listener-route.yaml
                    ├── trigger-*.yaml             # TriggerBindings and TriggerTemplates
                    ├── task-*.yaml                # Tekton Tasks
                    ├── es-*.yaml                  # ExternalSecrets (Vault-backed)
                    ├── webhook-job.yaml
                    ├── job-link-push-secret.yaml
                    └── pvc-build-cache.yaml
```



## Architecture

The build pipeline uses **hand-crafted Helm templates** rather than depending on a shared `build-deployer` chart. This keeps the template self-contained and avoids modifying shared infrastructure for template-specific features like cross-namespace rollout-restart.

The app deployment wraps the shared `app-deployer` chart from the GitLab Package Registry, which handles Deployment, Service, Route, Namespace, HPA, and ServiceMonitor resources.

## Adding More Templates

1. Create a new directory under `templates/` (e.g. `templates/go-app/`)
2. Add `template.yaml`, `skeleton/`, and `manifests/` following the same structure
3. Use `__PLACEHOLDER__` markers for cluster-specific values
4. Include `backstage.io/template-version` annotation in `template.yaml`
5. Include `spec.scaffoldedFrom: template:default/<template-name>` in the skeleton's `catalog-info.yaml`
6. Add the new template files to the `push-template.sh` `template_files` list
7. Run `./scripts/push-template.sh` to deploy

