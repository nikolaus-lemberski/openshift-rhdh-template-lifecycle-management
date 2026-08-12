#!/usr/bin/env bash
set -euo pipefail

#
# Push the Quarkus template into the rhdh-templates GitLab repo on a fresh cluster.
#
# Prerequisites:
#   - oc CLI logged in to the target OpenShift cluster (oc login ...)
#   - python3 available (for JSON payload construction)
#   - curl available
#
# Usage:
#   ./scripts/push-template.sh                      # auto-detect everything from cluster
#   ./scripts/push-template.sh --dry-run             # show what would be pushed without pushing
#   GITLAB_HOST=my-gitlab.example.com ./scripts/push-template.sh  # override auto-detection
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DRY_RUN=false

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

echo "==> Detecting cluster configuration..."

CLUSTER_SUBDOMAIN="${CLUSTER_SUBDOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
GITLAB_HOST="${GITLAB_HOST:-gitlab-gitlab.${CLUSTER_SUBDOMAIN}}"
GITLAB_TOKEN="${GITLAB_TOKEN:-$(oc get secret root-user-personal-token -n gitlab -o jsonpath='{.data.token}' | base64 -d)}"
QUAY_HOST="${QUAY_HOST:-quay.${CLUSTER_SUBDOMAIN}}"
GITOPS_NAMESPACE="${GITOPS_NAMESPACE:-rhdh-gitops}"

echo "    Cluster subdomain : ${CLUSTER_SUBDOMAIN}"
echo "    GitLab host       : ${GITLAB_HOST}"
echo "    GitLab token      : ${GITLAB_TOKEN:0:10}..."
echo "    Quay host         : ${QUAY_HOST}"
echo "    GitOps namespace  : ${GITOPS_NAMESPACE}"

gitlab_api() {
  local path="$1"
  shift
  curl -sk -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "https://${GITLAB_HOST}/api/v4${path}" "$@"
}

echo "==> Disabling GitLab Auto DevOps (prevents spurious GitLab CI pipelines)..."
AUTODEVOPS=$(gitlab_api "/application/settings" \
  | python3 -c "import sys,json; print(json.load(sys.stdin).get('auto_devops_enabled','unknown'))" 2>/dev/null)
if [[ "${AUTODEVOPS}" == "True" ]]; then
  gitlab_api "/application/settings" -X PUT --data-urlencode "auto_devops_enabled=false" > /dev/null 2>&1
  echo "    Disabled Auto DevOps at instance level"
else
  echo "    Auto DevOps already disabled"
fi

echo "==> Looking up rhdh-templates project ID..."
RHDH_TEMPLATES_ID=$(gitlab_api "/projects?search=rhdh-templates" \
  | python3 -c "import sys,json; projects=[p for p in json.load(sys.stdin) if p['path_with_namespace']=='rhdh/rhdh-templates']; print(projects[0]['id'] if projects else '')")

if [[ -z "${RHDH_TEMPLATES_ID}" ]]; then
  echo "ERROR: Could not find rhdh/rhdh-templates project in GitLab."
  echo "       Make sure the cluster setup has completed and the repo exists."
  exit 1
fi
echo "    Project ID        : ${RHDH_TEMPLATES_ID}"

echo "==> Fetching current catalog-info.yaml from GitLab..."
CURRENT_CATALOG=$(gitlab_api "/projects/${RHDH_TEMPLATES_ID}/repository/files/catalog-info.yaml/raw?ref=main" 2>/dev/null || echo "")

if echo "${CURRENT_CATALOG}" | grep -q "quarkus-app/template.yaml"; then
  echo "    Quarkus template already registered in catalog-info.yaml"
  UPDATE_CATALOG=false
else
  echo "    Quarkus template NOT yet in catalog-info.yaml, will add it"
  UPDATE_CATALOG=true
fi

echo "==> Fetching list of existing template files from GitLab..."
EXISTING_FILES=$(gitlab_api "/projects/${RHDH_TEMPLATES_ID}/repository/tree?path=templates/quarkus-app&recursive=true&per_page=100" 2>/dev/null \
  | python3 -c "import sys,json; [print(f['path']) for f in json.load(sys.stdin) if f['type']=='blob']" 2>/dev/null || echo "")
EXISTING_COUNT=$(echo "${EXISTING_FILES}" | grep -c "." 2>/dev/null || echo "0")
echo "    Found ${EXISTING_COUNT} existing files"

echo "==> Building commit payload (replacing placeholders with cluster values)..."

PAYLOAD_FILE=$(mktemp)
trap 'rm -f "${PAYLOAD_FILE}"' EXIT

python3 << PYEOF
import json, os, re

project_dir = "${PROJECT_DIR}"
update_catalog = ("${UPDATE_CATALOG}" == "true")
existing_files = set("""${EXISTING_FILES}""".strip().split("\n")) if """${EXISTING_FILES}""".strip() else set()

replacements = {
    "__GITLAB_HOST__": "${GITLAB_HOST}",
    "__CLUSTER_SUBDOMAIN__": "${CLUSTER_SUBDOMAIN}",
    "__QUAY_HOST__": "${QUAY_HOST}",
    "__GITOPS_NAMESPACE__": "${GITOPS_NAMESPACE}",
}

template_files = [
    "templates/quarkus-app/template.yaml",
    "templates/quarkus-app/skeleton/pom.xml",
    "templates/quarkus-app/skeleton/Containerfile",
    "templates/quarkus-app/skeleton/catalog-info.yaml",
    "templates/quarkus-app/skeleton/.gitignore",
    "templates/quarkus-app/skeleton/.dockerignore",
    "templates/quarkus-app/skeleton/src/main/java/org/acme/GreetingResource.java",
    "templates/quarkus-app/skeleton/src/main/resources/application.properties",
    "templates/quarkus-app/manifests/argocd/app-dev.yaml",
    "templates/quarkus-app/manifests/argocd/build.yaml",
    "templates/quarkus-app/manifests/app/Chart.yaml",
    "templates/quarkus-app/manifests/app/values/values-dev.yaml",
    "templates/quarkus-app/manifests/app/values/values-prod.yaml",
    "templates/quarkus-app/manifests/build/Chart.yaml",
    "templates/quarkus-app/manifests/build/values.yaml",
]

# Add all app Helm templates
app_templates_dir = os.path.join(project_dir, "templates/quarkus-app/manifests/app/templates")
for fname in sorted(os.listdir(app_templates_dir)):
    template_files.append(f"templates/quarkus-app/manifests/app/templates/{fname}")

# Add all build Helm templates
build_templates_dir = os.path.join(project_dir, "templates/quarkus-app/manifests/build/templates")
for fname in sorted(os.listdir(build_templates_dir)):
    template_files.append(f"templates/quarkus-app/manifests/build/templates/{fname}")

actions = []
for fpath in template_files:
    full_path = os.path.join(project_dir, fpath)
    with open(full_path, "r") as f:
        content = f.read()
    for placeholder, value in replacements.items():
        content = content.replace(placeholder, value)
    action = "update" if fpath in existing_files else "create"
    actions.append({
        "action": action,
        "file_path": fpath,
        "content": content,
    })

if update_catalog:
    current = """${CURRENT_CATALOG}"""
    if "./templates/quarkus-app/template.yaml" not in current:
        current = current.rstrip() + "\n    - ./templates/quarkus-app/template.yaml\n"
    actions.append({
        "action": "update",
        "file_path": "catalog-info.yaml",
        "content": current,
    })

payload = {
    "branch": "main",
    "commit_message": "Add Quarkus application template with CI/CD pipeline and ArgoCD",
    "actions": actions,
}

with open("${PAYLOAD_FILE}", "w") as f:
    json.dump(payload, f)

creates = sum(1 for a in actions if a["action"] == "create")
updates = sum(1 for a in actions if a["action"] == "update")
print(f"    Payload ready: {len(actions)} file actions ({creates} create, {updates} update)")
PYEOF

if [[ "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "==> DRY RUN: Would push the following files to rhdh/rhdh-templates (project ${RHDH_TEMPLATES_ID}):"
  python3 -c "import json; data=json.load(open('${PAYLOAD_FILE}')); [print(f'    {a[\"action\"]}: {a[\"file_path\"]}') for a in data['actions']]"
  echo ""
  echo "    To actually push, run without --dry-run"
  exit 0
fi

echo "==> Pushing to GitLab..."
RESPONSE=$(gitlab_api "/projects/${RHDH_TEMPLATES_ID}/repository/commits" \
  -w "\n%{http_code}" -X POST \
  -H "Content-Type: application/json" \
  -d @"${PAYLOAD_FILE}")

HTTP_CODE=$(echo "${RESPONSE}" | tail -1)
BODY=$(echo "${RESPONSE}" | sed '$d')

if [[ "${HTTP_CODE}" == "201" ]]; then
  COMMIT_SHA=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['short_id'])")
  COMMIT_URL=$(echo "${BODY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['web_url'])")
  echo ""
  echo "==> Success! Commit ${COMMIT_SHA}"
  echo "    ${COMMIT_URL}"
  echo ""
  echo "    The template will appear in Developer Hub within ~5 minutes"
  echo "    (GitLab catalog provider refresh interval)."
  echo ""
  echo "    RHDH URL: https://backstage-developer-hub-rhdh.${CLUSTER_SUBDOMAIN}"
  echo ""
  echo "    To enable automated template lifecycle management (auto-MRs on skeleton changes):"
  echo "    ./scripts/enable-template-lifecycle.sh"
  echo ""
  echo "    For scoped, review-friendly MRs instead of a full-repo diff, see:"
  echo "    ./scripts/disable-automated-lifecycle.sh and ./scripts/propagate-skeleton-diff.sh"
else
  echo ""
  echo "ERROR: GitLab API returned HTTP ${HTTP_CODE}"
  echo "${BODY}" | python3 -m json.tool 2>/dev/null || echo "${BODY}"
  exit 1
fi
