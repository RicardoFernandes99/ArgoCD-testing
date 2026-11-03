#!/usr/bin/env bash
# Installs kind and the argocd CLI inside the dev container.
# Runs automatically as the dev container's postCreateCommand.
set -euo pipefail

KIND_VERSION="v0.33.0"

case "$(uname -m)" in
  x86_64 | amd64) ARCH="amd64" ;;
  aarch64 | arm64) ARCH="arm64" ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if command -v kind >/dev/null 2>&1 && kind version | grep -q "$KIND_VERSION"; then
  echo "kind $KIND_VERSION already installed"
else
  echo "Installing kind $KIND_VERSION ($ARCH)..."
  curl -fsSL -o "$TMP_DIR/kind" "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
  sudo install -m 0755 "$TMP_DIR/kind" /usr/local/bin/kind
fi

# Match the CLI to the Argo CD "stable" release that bootstrap.sh installs.
ARGOCD_VERSION="$(curl -fsSL https://raw.githubusercontent.com/argoproj/argo-cd/stable/VERSION)"
ARGOCD_VERSION="v${ARGOCD_VERSION#v}"

if command -v argocd >/dev/null 2>&1 && argocd version --client --short 2>/dev/null | grep -q "$ARGOCD_VERSION"; then
  echo "argocd CLI $ARGOCD_VERSION already installed"
else
  echo "Installing argocd CLI $ARGOCD_VERSION ($ARCH)..."
  curl -fsSL -o "$TMP_DIR/argocd" \
    "https://github.com/argoproj/argo-cd/releases/download/${ARGOCD_VERSION}/argocd-linux-${ARCH}"
  sudo install -m 0755 "$TMP_DIR/argocd" /usr/local/bin/argocd
fi

# The workspace is often mounted with a different owner (e.g. from Windows);
# without this, git refuses to work in it ("dubious ownership").
if ! git config --global --get-all safe.directory | grep -qx "$PWD"; then
  git config --global --add safe.directory "$PWD"
fi

echo
kind version
argocd version --client --short
kubectl version --client
