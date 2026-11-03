#!/usr/bin/env bash
set -euo pipefail

# Install the Veeam KubeVirt Proxy (VKP) on an air-gapped Red Hat OpenShift
# Virtualization cluster, pulling its images from a private registry.
# Follows https://helpcenter.veeam.com/docs/vbr/userguide/vkp_install_proxy.html
#
# Usage: ./vkp-airgap.sh [download|push|install|all]
#   download  connected side: fetch the Helm chart and the images into a bundle
#   push      registry side: load the bundle images, retag and push them to the
#             private registry
#   install   cluster side: install the chart from the bundle, pointing it at
#             the private registry
#   all       the three steps in a row, from a bastion that reaches the
#             internet, the private registry and the cluster
#
# Every prompt can be skipped by exporting the matching variable beforehand,
# see the README for the list.

SCRIPT_VERSION="1.0.0"

VKP_HELM_REPO_URL="https://charts.veeam.com/"
VKP_SOURCE_REGISTRY="gcr.io/kasten-images"
# Images referenced by the chart: the vkp daemon (deployment.yaml) and the
# datamover it spawns for each backup/restore (DATA_MOVER_IMAGE env var).
VKP_IMAGES="vkp vkp-datamover"
# VKP images are only published for linux/amd64.
VKP_PLATFORM="linux/amd64"
VKP_RELEASE="vkp"

die() { echo -e "\033[0;31m ERROR: $* \033[0m" >&2; exit 1; }
warn() { echo -e "\033[0;33m WARNING: $* \033[0m" >&2; }
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

# ask_secret VAR "question": same as ask, without echoing the answer.
ask_secret() {
  local __var=$1 __question=$2 __answer
  [[ -n "${!__var:-}" ]] && return 0
  echo -e "\033[0;31m $__question: \033[0m"
  read -rs __answer < /dev/tty
  echo
  printf -v "$__var" '%s' "$__answer"
}

# is_yes VAR: true when VAR holds y/Y/yes.
is_yes() { [[ "${!1:-}" =~ ^([Yy]|[Yy][Ee][Ss])$ ]]; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
  else
    shasum -a 256 "$@"
  fi
}

# Docker and Podman are both supported, Podman is preferred when present as it
# is the default container tool on RHEL bastions.
detect_container_tool() {
  if [[ -z "${CONTAINER_TOOL:-}" ]]; then
    if command -v podman >/dev/null 2>&1; then
      CONTAINER_TOOL=podman
    elif command -v docker >/dev/null 2>&1; then
      CONTAINER_TOOL=docker
    else
      die "podman or docker is required but neither was found in PATH"
    fi
  fi
  require "$CONTAINER_TOOL"
  echo "Container tool: $CONTAINER_TOOL"
}

# bundle_get KEY: read a value from bundle.env without sourcing it, the bundle
# comes from removable media and is treated as data only.
bundle_get() {
  [[ -f "$BUNDLE_DIR/bundle.env" ]] || die "$BUNDLE_DIR/bundle.env not found, run the download step first"
  grep "^$1=" "$BUNDLE_DIR/bundle.env" | head -n1 | cut -d= -f2-
}

# version_lt CURRENT MINIMUM: true when CURRENT (x.y[.z]) is older than MINIMUM (x.y).
version_lt() {
  local cur_major cur_minor min_major min_minor
  cur_major=$(echo "$1" | cut -d. -f1); cur_minor=$(echo "$1" | cut -d. -f2)
  min_major=$(echo "$2" | cut -d. -f1); min_minor=$(echo "$2" | cut -d. -f2)
  (( cur_major < min_major || (cur_major == min_major && cur_minor < min_minor) ))
}

check_cli_versions() {
  local helm_version oc_version
  helm_version=$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//')
  if [[ -n "$helm_version" ]] && version_lt "$helm_version" "4.1"; then
    warn "Helm $helm_version found, the Veeam documentation requires Helm 4.1 or later"
  fi
  oc_version=$(oc version --client 2>/dev/null | awk '/Client Version/{print $3}')
  if [[ -n "$oc_version" ]] && version_lt "$oc_version" "4.20"; then
    warn "OpenShift CLI $oc_version found, the Veeam documentation requires 4.20 or later"
  fi
}

verify_bundle() {
  if [[ -f "$BUNDLE_DIR/SHA256SUMS" ]]; then
    step "Verifying bundle checksums"
    (cd "$BUNDLE_DIR" && sha256 -c SHA256SUMS) || die "checksum mismatch, the bundle was altered or corrupted during the transfer"
  else
    warn "no SHA256SUMS in $BUNDLE_DIR, skipping the integrity check"
  fi
}

do_download() {
  step "Download: Helm chart and images from the internet"
  require helm
  detect_container_tool
  ask BUNDLE_DIR "Output directory for the bundle" "./vkp-airgap-bundle"
  ask CHART_VERSION "VKP Helm chart version to download (leave empty for latest)" ""

  mkdir -p "$BUNDLE_DIR/chart" "$BUNDLE_DIR/images"

  # Step 3 of the Veeam procedure, done on the connected side: fetch the
  # chart locally instead of installing it straight from the repository.
  helm repo add veeamrepo "$VKP_HELM_REPO_URL" >/dev/null 2>&1 || true
  helm repo update veeamrepo

  if [[ -n "$CHART_VERSION" ]]; then
    helm pull veeamrepo/vkp --version "$CHART_VERSION" --destination "$BUNDLE_DIR/chart"
    chart_archive="$BUNDLE_DIR/chart/vkp-$CHART_VERSION.tgz"
  else
    helm pull veeamrepo/vkp --destination "$BUNDLE_DIR/chart"
    chart_archive=$(ls -t "$BUNDLE_DIR/chart"/vkp-*.tgz | head -n1)
  fi
  echo "Downloaded chart: $chart_archive"

  chart_version=$(tar -xzOf "$chart_archive" vkp/Chart.yaml | awk '/^version:/{print $2}' | tr -d '"')
  # With image.tag left empty the chart uses its appVersion, so this is the
  # tag the images must be pulled with.
  app_version=$(tar -xzOf "$chart_archive" vkp/Chart.yaml | awk '/^appVersion:/{print $2}' | tr -d '"')
  echo "VKP chart version: $chart_version, image tag (appVersion): $app_version"

  : > "$BUNDLE_DIR/images.txt"
  for image in $VKP_IMAGES; do
    src="$VKP_SOURCE_REGISTRY/$image:$app_version"
    archive="$BUNDLE_DIR/images/${image}_${app_version}.tar"
    step "Pulling $src ($VKP_PLATFORM)"
    "$CONTAINER_TOOL" pull --platform "$VKP_PLATFORM" "$src"
    echo "Saving to $archive"
    rm -f "$archive"
    if [[ "$CONTAINER_TOOL" == "podman" ]]; then
      podman save --format docker-archive -o "$archive" "$src"
    elif docker save --help 2>&1 | grep -q -- '--platform'; then
      # With the containerd image store, saving the whole index would fail on
      # the platforms that were not pulled.
      docker save --platform "$VKP_PLATFORM" -o "$archive" "$src"
    else
      docker save -o "$archive" "$src"
    fi
    echo "$src" >> "$BUNDLE_DIR/images.txt"
  done

  cat > "$BUNDLE_DIR/bundle.env" <<EOF
SCRIPT_VERSION=$SCRIPT_VERSION
CHART_FILE=chart/$(basename "$chart_archive")
CHART_VERSION=$chart_version
APP_VERSION=$app_version
SOURCE_REGISTRY=$VKP_SOURCE_REGISTRY
IMAGES=$VKP_IMAGES
PLATFORM=$VKP_PLATFORM
EOF

  # Ship the scripts with the bundle, the air-gapped side has no access to
  # GitHub to fetch them.
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  cp "$script_dir/vkp-airgap.sh" "$BUNDLE_DIR/"
  [[ -f "$script_dir/vkp-airgap-uninstall.sh" ]] && cp "$script_dir/vkp-airgap-uninstall.sh" "$BUNDLE_DIR/"

  (cd "$BUNDLE_DIR" && sha256 "chart/$(basename "$chart_archive")" images/*.tar > SHA256SUMS)

  echo
  echo "Bundle ready in $BUNDLE_DIR:"
  (cd "$BUNDLE_DIR" && ls -lR)
}

do_push() {
  step "Push: load the images and push them to the private registry"
  detect_container_tool
  ask BUNDLE_DIR "Directory of the VKP bundle" "./vkp-airgap-bundle"
  app_version=$(bundle_get APP_VERSION)
  source_registry=$(bundle_get SOURCE_REGISTRY)
  verify_bundle

  ask TARGET_REGISTRY "Private registry path to push the images to, e.g. registry.example.com/veeam" ""
  [[ -n "$TARGET_REGISTRY" ]] || die "a target registry is required"
  TARGET_REGISTRY=${TARGET_REGISTRY%/}
  ask TARGET_TAG "Tag to give the images in the private registry" "$app_version"

  registry_host=${TARGET_REGISTRY%%/*}
  ask REGISTRY_LOGIN "Log in to $registry_host before pushing? (y/N)" "N"
  if is_yes REGISTRY_LOGIN; then
    "$CONTAINER_TOOL" login "$registry_host" < /dev/tty
  fi

  for image in $(bundle_get IMAGES); do
    archive="$BUNDLE_DIR/images/${image}_${app_version}.tar"
    [[ -f "$archive" ]] || die "$archive not found in the bundle"
    src="$source_registry/$image:$app_version"
    dst="$TARGET_REGISTRY/$image:$TARGET_TAG"

    step "Loading $archive"
    "$CONTAINER_TOOL" load -i "$archive"

    echo "Tagging $src as $dst"
    "$CONTAINER_TOOL" tag "$src" "$dst"

    echo "Pushing $dst"
    if [[ "$CONTAINER_TOOL" == "docker" ]] && docker push --help 2>&1 | grep -q -- '--platform'; then
      docker push --platform "$VKP_PLATFORM" "$dst"
    else
      "$CONTAINER_TOOL" push "$dst"
    fi
  done

  echo
  echo "Images available in the private registry:"
  for image in $(bundle_get IMAGES); do
    echo "  $TARGET_REGISTRY/$image:$TARGET_TAG"
  done
}

oc_login_if_needed() {
  if oc whoami >/dev/null 2>&1; then
    echo "Connected to $(oc whoami --show-server) as $(oc whoami)"
    return 0
  fi
  # Step 2 of the Veeam procedure.
  ask OC_SERVER "OpenShift API address, e.g. https://api.cluster.example.com:6443" ""
  ask OC_USER "OpenShift user with cluster-admin permissions" ""
  oc login --server="$OC_SERVER" -u "$OC_USER" < /dev/tty
}

annotate_snapshot_class() {
  local vsc_count
  vsc_count=$(oc get volumesnapshotclass -o name 2>/dev/null | wc -l | tr -d ' ')
  if (( vsc_count <= 1 )); then
    echo "$vsc_count VolumeSnapshotClass found, no annotation needed"
    return 0
  fi

  # Step 5 of the Veeam procedure, only needed with several snapshot classes.
  step "Several VolumeSnapshotClasses found, VKP needs to know which one to use"
  oc get storageclass
  echo
  oc get volumesnapshotclass
  echo
  echo " 1) Skip"
  echo " 2) Use a given VolumeSnapshotClass for the volumes of a given StorageClass"
  echo " 3) Use one VolumeSnapshotClass for every snapshot"
  ask SNAPSHOT_MODE "Choice" "1"
  case "$SNAPSHOT_MODE" in
    2)
      ask SNAPSHOT_STORAGE_CLASS "StorageClass of the volumes to protect" ""
      ask SNAPSHOT_CLASS "VolumeSnapshotClass to use for it" ""
      oc annotate storageclass "$SNAPSHOT_STORAGE_CLASS" \
        "vkp.veeam.com/volume-snapshot-class=$SNAPSHOT_CLASS" --overwrite
      ;;
    3)
      ask SNAPSHOT_CLASS "VolumeSnapshotClass to use for every snapshot" ""
      oc annotate volumesnapshotclass "$SNAPSHOT_CLASS" \
        "vkp.veeam.com/is-snapshot-class=true" --overwrite
      ;;
    *)
      echo "Skipped, see the README to annotate later"
      ;;
  esac
}

do_install() {
  step "Install: VKP on OpenShift from the private registry"
  require oc helm jq base64
  check_cli_versions
  ask BUNDLE_DIR "Directory of the VKP bundle" "./vkp-airgap-bundle"
  chart_archive="$BUNDLE_DIR/$(bundle_get CHART_FILE)"
  app_version=$(bundle_get APP_VERSION)
  [[ -f "$chart_archive" ]] || die "$chart_archive not found"
  verify_bundle

  ask TARGET_REGISTRY "Private registry path holding the VKP images, e.g. registry.example.com/veeam" ""
  [[ -n "$TARGET_REGISTRY" ]] || die "a target registry is required"
  TARGET_REGISTRY=${TARGET_REGISTRY%/}
  ask TARGET_TAG "Tag of the VKP images in the private registry" "$app_version"
  ask VKP_NAMESPACE "Namespace to install VKP in" "vkp"

  oc_login_if_needed
  oc api-resources --api-group=route.openshift.io -o name 2>/dev/null | grep -q '^routes' \
    || die "the current cluster is not OpenShift (no route.openshift.io API)"
  oc get crd virtualmachines.kubevirt.io >/dev/null 2>&1 \
    || warn "OpenShift Virtualization (KubeVirt) does not seem to be installed on this cluster"

  step "Veeam License Agreement"
  tar -xzOf "$chart_archive" vkp/eula.txt
  echo
  ask EULA_ACCEPT "Do you accept the Veeam License Agreement? (y/N)" "N"
  is_yes EULA_ACCEPT || die "the EULA must be accepted to install VKP"
  ask EULA_COMPANY "Company name recorded with the EULA acceptance (optional)" ""
  ask EULA_EMAIL "Email recorded with the EULA acceptance (optional)" ""

  # VKP checks chartRepo for newer versions and reports them to Veeam Backup
  # & Replication, point it at an internal mirror of charts.veeam.com if any.
  ask CHART_REPO_URL "Internal Helm repository mirroring charts.veeam.com (leave empty to keep $VKP_HELM_REPO_URL)" ""

  ask PULL_AUTH "Does the private registry require authentication to pull images? (y/N)" "N"
  docker_config=""
  if is_yes PULL_AUTH; then
    registry_host=${TARGET_REGISTRY%%/*}
    ask REGISTRY_USER "Username for $registry_host" ""
    ask_secret REGISTRY_PASSWORD "Password or token for $registry_host"
    auth=$(printf '%s:%s' "$REGISTRY_USER" "$REGISTRY_PASSWORD" | base64 | tr -d '\n')
    docker_config=$(jq -jcn --arg host "$registry_host" --arg auth "$auth" \
      '{auths: {($host): {auth: $auth}}}' | base64 | tr -d '\n')
  fi

  # Values go through a private temporary file rather than --set, so that the
  # registry credentials never show up in the process list or shell history.
  values_file=$(mktemp)
  chmod 600 "$values_file"
  trap 'rm -f "$values_file"' EXIT
  jq -n \
    --arg registry "$TARGET_REGISTRY" \
    --arg tag "$TARGET_TAG" \
    --arg company "$EULA_COMPANY" \
    --arg email "$EULA_EMAIL" \
    --arg chartRepo "$CHART_REPO_URL" \
    --arg dockerConfig "$docker_config" \
    '{
      image: {registry: $registry, tag: $tag},
      eula: {accept: true, company: $company, email: $email},
      secrets: {dockerConfig: $dockerConfig}
    } + (if $chartRepo != "" then {chartRepo: $chartRepo} else {} end)' > "$values_file"

  # Step 4 of the Veeam procedure, with the air-gapped parameters
  # (image.registry, image.tag, chartRepo) and the chart taken from the bundle.
  step "Installing $VKP_RELEASE in namespace $VKP_NAMESPACE"
  helm upgrade --install "$VKP_RELEASE" "$chart_archive" \
    --namespace "$VKP_NAMESPACE" --create-namespace \
    -f "$values_file" \
    --wait --timeout 10m

  if [[ -n "$docker_config" ]]; then
    # The chart only sets the pull secret on the vkp deployment, linking it to
    # the service account also covers the datamover pods VKP creates.
    oc secrets link vkp vkp-ecr --for=pull -n "$VKP_NAMESPACE"
  fi

  oc get pods -n "$VKP_NAMESPACE" -o wide

  annotate_snapshot_class

  # Step 6 of the Veeam procedure: details to enter in Veeam Backup &
  # Replication when adding the Red Hat OpenShift Virtualization server.
  step "VKP connection details for Veeam Backup & Replication"
  vkp_host=$(oc get route vkp -n "$VKP_NAMESPACE" -o jsonpath='{.spec.host}')
  vkp_token=$(oc get secret vkp-token -n "$VKP_NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
  echo "FQDN:  $vkp_host"
  echo "Token (keep it private):"
  echo "$vkp_token"
  echo
  echo "To display them again:"
  echo "  oc get route vkp -n $VKP_NAMESPACE"
  echo "  oc get secret vkp-token -n $VKP_NAMESPACE -o jsonpath='{.data.token}' | base64 -d"
}

echo "vkp-airgap.sh version $SCRIPT_VERSION"

mode=${1:-}
if [[ -z "$mode" ]]; then
  echo " 1) download  fetch the chart and images into a bundle (connected side)"
  echo " 2) push      push the bundle images to the private registry"
  echo " 3) install   install VKP on OpenShift from the private registry"
  echo " 4) all       the three steps in a row"
  ask MODE_CHOICE "Choice" ""
  case "$MODE_CHOICE" in
    1) mode=download ;;
    2) mode=push ;;
    3) mode=install ;;
    4) mode=all ;;
    *) mode=$MODE_CHOICE ;;
  esac
fi

case "$mode" in
  download) do_download ;;
  push) do_push ;;
  install) do_install ;;
  all) do_download; do_push; do_install ;;
  *) die "unknown mode '$mode', expected download, push, install or all" ;;
esac

echo
echo "Done."
exit 0
