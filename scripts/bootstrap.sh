#!/usr/bin/env bash
# Creates a local kind cluster, installs Argo CD, registers the demo
# Application and exposes the Argo CD UI on port 8080.
# Safe to run more than once.
set -euo pipefail

CLUSTER_NAME="argo-poc"
ARGOCD_NAMESPACE="argocd"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
METRICS_SERVER_VERSION="v0.9.1"
UI_PORT="8080"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing '$tool'. Run this inside the dev container." >&2
    exit 1
  fi
done

log "Creating kind cluster '$CLUSTER_NAME'"
if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  echo "Cluster already exists, skipping."
elif [[ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" == "1" ]]; then
  # Recent kubelets refuse to start on cgroup v1 hosts (e.g. some Docker
  # Desktop / WSL2 setups). Opt back in so the POC still runs there.
  echo "Docker host uses cgroup v1; enabling kubelet failCgroupV1=false."
  kind create cluster --name "$CLUSTER_NAME" --wait 120s --config - <<'KIND'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        failCgroupV1: false
KIND
else
  kind create cluster --name "$CLUSTER_NAME" --wait 120s
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

log "Installing Argo CD (stable) into namespace '$ARGOCD_NAMESPACE'"
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_MANIFEST"

# Serve the UI over plain HTTP behind the port-forward. This avoids self-signed
# certificate problems in the browser and in Codespaces port forwarding.
# Fine for a local POC; do not do this in production.
current="$(kubectl -n "$ARGOCD_NAMESPACE" get configmap argocd-cmd-params-cm \
  -o jsonpath='{.data.server\.insecure}' 2>/dev/null || true)"
if [[ "$current" != "true" ]]; then
  kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
    --type merge -p '{"data":{"server.insecure":"true"}}'
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server
fi

log "Waiting for argocd-server to be ready"
kubectl -n "$ARGOCD_NAMESPACE" rollout status deployment/argocd-server --timeout=300s
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s

log "Installing metrics-server $METRICS_SERVER_VERSION (needed by the api autoscaler)"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
# kind's kubelets use self-signed certificates.
if ! kubectl -n kube-system get deployment metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

log "Registering the demo Application"
kubectl apply -f "$REPO_ROOT/application.yaml"

log "Argo CD admin credentials"
password=""
for _ in $(seq 1 30); do
  password="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || true)"
  [[ -n "$password" ]] && break
  sleep 2
done
echo "  username: admin"
if [[ -n "$password" ]]; then
  echo "  password: $password"
else
  echo "  password: (argocd-initial-admin-secret not found; was it deleted after a password change?)"
fi

log "Argo CD UI: http://localhost:$UI_PORT  (Ctrl+C stops the port-forward; the cluster keeps running)"
exec kubectl port-forward --address 0.0.0.0 -n "$ARGOCD_NAMESPACE" svc/argocd-server "$UI_PORT:80"
