#!/usr/bin/env bash
set -euo pipefail

#
# Enable automated Software Template lifecycle management on the RHDH instance.
#
# This configures the scaffolder-relation-processor plugin and PR creation so
# that changes to the template skeleton are automatically rolled out as merge
# requests to all downstream repositories created from the template.
#
# Prerequisites:
#   - oc CLI logged in to the target OpenShift cluster
#   - RHDH is running in the 'rhdh' namespace
#   - python3 available locally
#
# What this script does:
#   1. Enables the scaffolder-relation-processor dynamic plugin
#   2. Adds scaffolder.pullRequests.templateUpdate config to app-config
#   3. Adds ArgoCD ignoreDifferences so the changes aren't reverted
#   4. Restarts the RHDH pod to apply changes
#   5. Verifies the plugin is actually loaded and running (not just configured)
#
# Usage:
#   ./scripts/enable-template-lifecycle.sh
#   ./scripts/enable-template-lifecycle.sh --dry-run
#

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
RHDH_NAMESPACE="${RHDH_NAMESPACE:-rhdh}"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-developer-hub-application}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-openshift-gitops}"

if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

PLUGIN_PACKAGE="./dynamic-plugins/dist/backstage-community-plugin-catalog-backend-module-scaffolder-relation-processor-dynamic"

echo "==> Checking RHDH namespace..."
if ! oc get namespace "${RHDH_NAMESPACE}" &>/dev/null; then
  echo "ERROR: Namespace '${RHDH_NAMESPACE}' not found. Set RHDH_NAMESPACE if different."
  exit 1
fi

echo "==> Checking current dynamic-plugins ConfigMap..."
DYNAMIC_PLUGINS_CM=$(oc get backstage -n "${RHDH_NAMESPACE}" -o jsonpath='{.items[0].spec.application.dynamicPluginsConfigMapName}' 2>/dev/null || echo "dynamic-plugins")
echo "    ConfigMap name: ${DYNAMIC_PLUGINS_CM}"

is_relation_processor_enabled() {
  # Reads the ConfigMap fresh from the cluster every time it's called, rather
  # than trusting a value cached earlier in the script — the whole point is to
  # catch cases where a write silently didn't stick or got reverted later.
  local current
  current=$(oc get configmap "${DYNAMIC_PLUGINS_CM}" -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.dynamic-plugins\.yaml}' 2>/dev/null || echo "")
  echo "${current}" | grep -q "relation-processor" && echo "${current}" | grep -A 1 "relation-processor" | grep -q "disabled: false"
}

CURRENT_DYNAMIC=$(oc get configmap "${DYNAMIC_PLUGINS_CM}" -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.dynamic-plugins\.yaml}')

if is_relation_processor_enabled; then
  echo "    Scaffolder relation processor already enabled in dynamic-plugins"
  DYNAMIC_NEEDS_UPDATE=false
else
  echo "    Scaffolder relation processor not enabled, will add it"
  DYNAMIC_NEEDS_UPDATE=true
fi

echo "==> Checking current app-config-rhdh ConfigMap..."
CURRENT_APPCONFIG=$(oc get configmap app-config-rhdh -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.app-config-rhdh\.yaml}')

if echo "${CURRENT_APPCONFIG}" | grep -q "templateUpdate"; then
  echo "    Template update config already present in app-config"
  APPCONFIG_NEEDS_UPDATE=false
else
  echo "    Template update config not found, will add it"
  APPCONFIG_NEEDS_UPDATE=true
fi

NEEDS_UPDATE=false
[[ "${DYNAMIC_NEEDS_UPDATE}" == "true" || "${APPCONFIG_NEEDS_UPDATE}" == "true" ]] && NEEDS_UPDATE=true

if [[ "${NEEDS_UPDATE}" == "false" ]]; then
  echo ""
  echo "==> ConfigMaps already look correct. Skipping straight to a runtime check —"
  echo "    a correct-looking ConfigMap doesn't guarantee the plugin is actually running."
fi

if [[ "${NEEDS_UPDATE}" == "true" && "${DRY_RUN}" == "true" ]]; then
  echo ""
  echo "==> DRY RUN: Would make the following changes:"
  [[ "${DYNAMIC_NEEDS_UPDATE}" == "true" ]] && echo "    - Enable scaffolder-relation-processor plugin in ${DYNAMIC_PLUGINS_CM} ConfigMap"
  [[ "${APPCONFIG_NEEDS_UPDATE}" == "true" ]] && echo "    - Add scaffolder.pullRequests.templateUpdate config to app-config-rhdh"
  echo "    - Add ArgoCD ignoreDifferences for ConfigMaps (if managed by ArgoCD)"
  echo "    - Restart RHDH pod"
  echo ""
  echo "    To apply, run without --dry-run"
  exit 0
fi

if [[ "${DYNAMIC_NEEDS_UPDATE}" == "true" ]]; then
  echo "==> Updating dynamic-plugins ConfigMap..."
  TMPFILE=$(mktemp)
  echo "${CURRENT_DYNAMIC}" > "${TMPFILE}"

  if echo "${CURRENT_DYNAMIC}" | grep -q "relation-processor"; then
    python3 -c "
import re, sys
content = open('${TMPFILE}').read()
content = re.sub(
    r'(- package:.*relation-processor.*\n\s+disabled:) true',
    r'\1 false',
    content
)
open('${TMPFILE}', 'w').write(content)
"
  else
    python3 -c "
content = open('${TMPFILE}').read()
entry = '''
  # Scaffolder relation processor (automated template lifecycle management)
  - package: ${PLUGIN_PACKAGE}
    disabled: false
'''
content = content.rstrip() + '\n' + entry
open('${TMPFILE}', 'w').write(content)
"
  fi

  oc create configmap "${DYNAMIC_PLUGINS_CM}" -n "${RHDH_NAMESPACE}" \
    --from-file="dynamic-plugins.yaml=${TMPFILE}" \
    --dry-run=client -o yaml | oc apply -f -
  rm -f "${TMPFILE}"

  echo "    Confirming the write actually stuck..."
  if ! is_relation_processor_enabled; then
    echo ""
    echo "ERROR: Applied the ConfigMap update, but re-reading it back from the cluster"
    echo "       shows the relation-processor entry is still missing or disabled."
    echo "       Something rejected or reverted the change immediately (e.g. an operator"
    echo "       or GitOps controller managing this ConfigMap). Inspect manually:"
    echo "       oc get configmap ${DYNAMIC_PLUGINS_CM} -n ${RHDH_NAMESPACE} -o jsonpath='{.data.dynamic-plugins\.yaml}' | grep -A2 relation-processor"
    exit 1
  fi
  echo "    Done"
fi

if [[ "${APPCONFIG_NEEDS_UPDATE}" == "true" ]]; then
  echo "==> Updating app-config-rhdh ConfigMap..."
  TMPFILE=$(mktemp)
  echo "${CURRENT_APPCONFIG}" > "${TMPFILE}"

  python3 -c "
content = open('${TMPFILE}').read()
scaffolder_block = '''scaffolder:
  pullRequests:
    templateUpdate:
      enabled: true
  notifications:
    templateUpdate:
      enabled: true

'''
if 'integrations:' in content:
    content = content.replace('integrations:', scaffolder_block + 'integrations:')
else:
    content = content.rstrip() + '\n\n' + scaffolder_block
open('${TMPFILE}', 'w').write(content)
"

  oc create configmap app-config-rhdh -n "${RHDH_NAMESPACE}" \
    --from-file="app-config-rhdh.yaml=${TMPFILE}" \
    --dry-run=client -o yaml | oc apply -f -
  rm -f "${TMPFILE}"

  echo "    Confirming the write actually stuck..."
  APPLIED_APPCONFIG=$(oc get configmap app-config-rhdh -n "${RHDH_NAMESPACE}" -o jsonpath='{.data.app-config-rhdh\.yaml}')
  if ! echo "${APPLIED_APPCONFIG}" | grep -q "templateUpdate"; then
    echo ""
    echo "ERROR: Applied the app-config-rhdh update, but re-reading it back shows"
    echo "       'templateUpdate' is still missing. Something rejected or reverted it."
    exit 1
  fi
  echo "    Done"
fi

echo "==> Checking ArgoCD management..."
if oc get application "${ARGOCD_APP_NAME}" -n "${ARGOCD_NAMESPACE}" &>/dev/null; then
  echo "    RHDH is managed by ArgoCD, (re-)adding ignoreDifferences..."
  # Re-applied unconditionally (even if it looks already configured) since a full
  # resync of the Application manifest from Git can silently drop this patch,
  # which then lets ArgoCD revert the ConfigMap changes above on the next sync.
  oc patch application "${ARGOCD_APP_NAME}" -n "${ARGOCD_NAMESPACE}" --type=merge -p '{
    "spec": {
      "ignoreDifferences": [
        {
          "group": "",
          "kind": "ConfigMap",
          "name": "'"${DYNAMIC_PLUGINS_CM}"'",
          "namespace": "'"${RHDH_NAMESPACE}"'",
          "jsonPointers": ["/data"]
        },
        {
          "group": "",
          "kind": "ConfigMap",
          "name": "app-config-rhdh",
          "namespace": "'"${RHDH_NAMESPACE}"'",
          "jsonPointers": ["/data"]
        }
      ]
    }
  }'
  echo "    Done"
else
  echo "    No ArgoCD application found, skipping"
fi

restart_rhdh_pod() {
  echo "==> Restarting RHDH pod..."
  local pod_name
  pod_name=$(oc get pods -n "${RHDH_NAMESPACE}" -o name | grep backstage-developer-hub | grep -v psql | head -1)
  if [[ -n "${pod_name}" ]]; then
    oc delete "${pod_name}" -n "${RHDH_NAMESPACE}"
    echo "    Waiting for new pod to be ready..."
    oc rollout status deploy/backstage-developer-hub -n "${RHDH_NAMESPACE}" --timeout=300s
    echo "    Done"
    return 0
  else
    echo "    WARNING: Could not find RHDH pod to restart"
    return 1
  fi
}

# Verifies the plugin is actually loaded by the running backend, not just
# present in a ConfigMap somewhere. Polls for up to 60s instead of a single
# fixed sleep, since plugin loading takes a few seconds after the pod reports
# ready. Surfaces any relation-processor-related log lines it finds so a real
# load failure (bad package path, crash, etc.) doesn't look identical to "not
# checked yet".
verify_plugin_loaded() {
  echo "==> Verifying plugin loaded..."
  local i logs related
  for i in $(seq 1 12); do
    logs=$(oc logs deploy/backstage-developer-hub -n "${RHDH_NAMESPACE}" -c backstage-backend --since=2m 2>/dev/null || echo "")
    if echo "${logs}" | grep -qi "loaded dynamic backend plugin.*relation-processor"; then
      echo "    Scaffolder relation processor plugin loaded successfully"
      return 0
    fi
    related=$(echo "${logs}" | grep -i "relation-processor" || true)
    sleep 5
  done

  echo ""
  echo "ERROR: Plugin did not report as loaded within 60s."
  if [[ -n "${related}" ]]; then
    echo "    Related log lines found (may indicate why it failed to load):"
    echo "${related}" | sed 's/^/    /'
  else
    echo "    No mention of relation-processor in backend logs at all — the ConfigMap"
    echo "    change may not have reached the running pod. Check:"
    echo "    oc get configmap ${DYNAMIC_PLUGINS_CM} -n ${RHDH_NAMESPACE} -o jsonpath='{.data.dynamic-plugins\.yaml}' | grep -A2 relation-processor"
  fi
  return 1
}

if [[ "${NEEDS_UPDATE}" == "true" ]]; then
  restart_rhdh_pod || true
  if ! verify_plugin_loaded; then
    exit 1
  fi
else
  # Config already looked correct going in, but that's exactly the situation
  # that caused the original bug: a ConfigMap can look right while the running
  # pod predates it, crashed on load, or never actually picked it up. Verify
  # live; if it's not running, restart once and check again before giving up.
  if ! verify_plugin_loaded; then
    echo "    Config looks correct but the plugin isn't running — restarting once to recover..."
    restart_rhdh_pod || true
    if ! verify_plugin_loaded; then
      echo ""
      echo "ERROR: Plugin still not loaded after a restart, even though the ConfigMap"
      echo "       looks correct. This needs manual investigation."
      exit 1
    fi
  fi
fi

echo ""
echo "==> Template lifecycle management is configured and verified running!"
echo ""
echo "    How it works:"
echo "    1. Apps created from the template will have spec.scaffoldedFrom in their catalog-info.yaml"
echo "    2. When you bump backstage.io/template-version in template.yaml and push, the plugin"
echo "       detects the version change and creates a GitLab MR in each downstream repo"
echo "    3. The MR contains the file differences between the old and new skeleton"
echo ""
echo "    To test:"
echo "    1. Create an app from the template"
echo "    2. Edit the skeleton (e.g. add a new endpoint to app.py)"
echo "    3. Bump the version in template.yaml"
echo "    4. Run ./scripts/push-template.sh"
echo "    5. Wait ~5 minutes for catalog refresh"
echo "    6. Check GitLab for a merge request in the app's repo"
