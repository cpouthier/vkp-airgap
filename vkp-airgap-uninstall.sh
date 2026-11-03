#!/usr/bin/env bash
set -euo pipefail

# Remove what vkp-airgap.sh installed: the VKP Helm release, its namespace,
# the snapshot class annotations and, optionally, the local images and bundle.
# Follows https://helpcenter.veeam.com/docs/vbr/userguide/vkp_uninstall_proxy.html
#
# Usage: ./vkp-airgap-uninstall.sh

SCRIPT_VERSION="1.0.0"

VKP_RELEASE="vkp"

die() { echo -e "\033[0;31m ERROR: $* \033[0m" >&2; exit 1; }
step() { echo; echo -e "\033[0;32m==> $* \033[0m"; }

require() {
  local cmd
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null 2>&1 || die "$cmd is required but not found in PATH"
  done
}

# ask VAR "question" [default]: prompt for VAR unless it is already set.
ask() {
  local __var=$1 __question=$2 __default=${3:-} __answer
  [[ -n "${!__var:-}" ]] && return 0
  if [[ -n "$__default" ]]; then
    echo -e "\033[0;31m $__question (default: $__default): \033[0m"
  else
    echo -e "\033[0;31m $__question: \033[0m"
  fi
  read -r __answer < /dev/tty
  printf -v "$__var" '%s' "${__answer:-$__default}"
}

# is_yes VAR: true when VAR holds y/Y/yes.
is_yes() { [[ "${!1:-}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; }

echo "vkp-airgap-uninstall.sh version $SCRIPT_VERSION"
require oc helm

oc whoami >/dev/null 2>&1 || die "not logged in to OpenShift, run oc login first"
echo "Connected to $(oc whoami --show-server) as $(oc whoami)"

ask VKP_NAMESPACE "Namespace VKP is installed in" "vkp"

echo -e "\033[0;33m Veeam recommends removing the Red Hat OpenShift Virtualization server from the Veeam Backup & Replication infrastructure first. \033[0m"
ask CONFIRM "Uninstall VKP from namespace $VKP_NAMESPACE and delete the namespace? (y/N)" "N"
is_yes CONFIRM || { echo "Aborted."; exit 0; }

step "Removing the Helm release"
if helm status "$VKP_RELEASE" -n "$VKP_NAMESPACE" >/dev/null 2>&1; then
  helm uninstall "$VKP_RELEASE" -n "$VKP_NAMESPACE" --wait
else
  echo "No $VKP_RELEASE release in $VKP_NAMESPACE"
fi

# Cluster-scoped objects are named after the namespace and removed by helm,
# this only catches leftovers from an interrupted install.
oc delete clusterrolebinding,clusterrole "vkp-$VKP_NAMESPACE" --ignore-not-found
oc delete scc "vkp-$VKP_NAMESPACE-scc" --ignore-not-found

step "Removing the namespace"
oc delete namespace "$VKP_NAMESPACE" --ignore-not-found --wait

step "Snapshot class annotations"
annotated=""
for sc in $(oc get storageclass -o name 2>/dev/null); do
  if [[ -n "$(oc get "$sc" -o jsonpath='{.metadata.annotations.vkp\.veeam\.com/volume-snapshot-class}')" ]]; then
    annotated="$annotated $sc"
  fi
done
for vsc in $(oc get volumesnapshotclass -o name 2>/dev/null); do
  if [[ -n "$(oc get "$vsc" -o jsonpath='{.metadata.annotations.vkp\.veeam\.com/is-snapshot-class}')" ]]; then
    annotated="$annotated $vsc"
  fi
done
if [[ -n "$annotated" ]]; then
  echo "Annotated by VKP:$annotated"
  ask REMOVE_ANNOTATIONS "Remove these annotations? (y/N)" "N"
  if is_yes REMOVE_ANNOTATIONS; then
    for obj in $annotated; do
      case "$obj" in
        storageclass*) oc annotate "$obj" vkp.veeam.com/volume-snapshot-class- ;;
        *) oc annotate "$obj" vkp.veeam.com/is-snapshot-class- ;;
      esac
    done
  fi
else
  echo "No VKP annotation found"
fi

step "Local cleanup"
container_tool=${CONTAINER_TOOL:-}
if [[ -z "$container_tool" ]]; then
  if command -v podman >/dev/null 2>&1; then
    container_tool=podman
  elif command -v docker >/dev/null 2>&1; then
    container_tool=docker
  fi
fi
if [[ -n "$container_tool" ]]; then
  local_images=$("$container_tool" images --format '{{.Repository}}:{{.Tag}}' | grep -E '/vkp(-datamover)?:' || true)
  if [[ -n "$local_images" ]]; then
    echo "Local VKP images:"
    echo "$local_images"
    ask REMOVE_IMAGES "Remove these local images? (y/N)" "N"
    if is_yes REMOVE_IMAGES; then
      for image in $local_images; do
        "$container_tool" rmi "$image" || true
      done
    fi
  fi
fi

ask BUNDLE_DIR "Local bundle directory to delete (leave empty to keep it)" ""
if [[ -n "$BUNDLE_DIR" ]]; then
  [[ -f "$BUNDLE_DIR/bundle.env" ]] || die "$BUNDLE_DIR does not look like a VKP bundle (no bundle.env), not deleting it"
  rm -rf "$BUNDLE_DIR"
  echo "Deleted $BUNDLE_DIR"
fi

echo
echo "Done. Images pushed to the private registry are left in place, remove them with your registry's own tooling if needed."
exit 0
