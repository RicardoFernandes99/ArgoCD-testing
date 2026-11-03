#!/usr/bin/env bash
# Creates (or repairs) the local kind cluster, installs Argo CD and
# metrics-server, and registers the demo Application.
#
# The cluster publishes two fixed ports, so no port-forward is needed:
#   8080 -> Argo CD UI       (argocd-server NodePort 30080)
#   8081 -> demo app (web)   (web NodePort 30081, defined in app/web.yaml)
#
# Safe to run any number of times. Usually called through ./demo.sh up.
set -euo pipefail

CLUSTER_NAME="argo-poc"
CONTEXT="kind-$CLUSTER_NAME"
NODE="$CLUSTER_NAME-control-plane"
ARGOCD_NAMESPACE="argocd"
ARGOCD_MANIFEST="https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml"
METRICS_SERVER_VERSION="v0.9.1"
UI_PORT="8080"
APP_PORT="8081"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }

for tool in docker kind kubectl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing '$tool'. Run this inside the dev container." >&2
    exit 1
  fi
done

cluster_exists() { kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; }
api_ready() { kubectl --context "$CONTEXT" get --raw /readyz --request-timeout=5s >/dev/null 2>&1; }
has_port_mappings() { docker port "$NODE" 2>/dev/null | grep -q "0.0.0.0:$UI_PORT"; }

kind_config() {
  cat <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - containerPort: 30080   # Argo CD UI
        hostPort: $UI_PORT
        listenAddress: "0.0.0.0"
      - containerPort: 30081   # demo app (web)
        hostPort: $APP_PORT
        listenAddress: "0.0.0.0"
EOF
  # Recent kubelets refuse to start on cgroup v1 hosts (e.g. some Docker
  # Desktop / WSL2 setups). Opt back in so the POC still runs there.
  if [[ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" == "1" ]]; then
    cat <<'EOF'
    kubeadmConfigPatches:
      - |
        kind: KubeletConfiguration
        failCgroupV1: false
EOF
  fi
}

cgroup_v1() { [[ "$(docker info --format '{{.CgroupVersion}}' 2>/dev/null)" == "1" ]]; }

create_cluster() {
  # Old versions of this POC used port-forwards on the same ports.
  pkill -f "kubectl port-forward" 2>/dev/null || true
  if cgroup_v1; then
    echo "Docker host uses cgroup v1; enabling kubelet failCgroupV1=false."
  fi
  if ! kind_config | kind create cluster --name "$CLUSTER_NAME" --wait 120s --config -; then
    kind delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
    if cgroup_v1; then
      cat >&2 <<'EOF'

The cluster failed to start. On cgroup v1 Docker hosts this happens when a
cluster is created again after one was deleted in the same dev container
session. To fix it:
  1. Restart the dev container: F1 -> "Dev Containers: Rebuild Container"
     (or stop/start the codespace),
  2. run ./demo.sh up again.
To stop this for good, switch Docker to cgroup v2 (see README, Troubleshooting).
EOF
    fi
    exit 1
  fi
}

log "Cluster '$CLUSTER_NAME'"
if ! cluster_exists; then
  create_cluster
elif ! has_port_mappings; then
  echo "Cluster was created without fixed ports 8080/8081; recreating it."
  echo "(Nothing is lost: Argo CD redeploys the app from Git.)"
  kind delete cluster --name "$CLUSTER_NAME"
  create_cluster
elif api_ready; then
  echo "Cluster is running."
else
  echo "Cluster exists but is not responding; starting its node container..."
  docker start "$NODE" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do api_ready && break; sleep 3; done
  if api_ready; then
    echo "Cluster is back."
  elif cgroup_v1; then
    echo "Cluster did not recover. Restart the dev container and run ./demo.sh up again." >&2
    echo "(If that does not help: ./demo.sh down, restart the dev container, ./demo.sh up.)" >&2
    exit 1
  else
    echo "Cluster did not recover; recreating it (Argo CD will redeploy the app from Git)."
    kind delete cluster --name "$CLUSTER_NAME"
    create_cluster
  fi
fi
kubectl config use-context "$CONTEXT" >/dev/null

log "Argo CD (stable) in namespace '$ARGOCD_NAMESPACE'"
kubectl create namespace "$ARGOCD_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side --force-conflicts -n "$ARGOCD_NAMESPACE" -f "$ARGOCD_MANIFEST" >/dev/null
echo "Argo CD manifests applied."

# Serve the UI over plain HTTP. This avoids self-signed certificate problems in
# the browser and in Codespaces port forwarding.
# Fine for a local POC; do not do this in production.
current="$(kubectl -n "$ARGOCD_NAMESPACE" get configmap argocd-cmd-params-cm \
  -o jsonpath='{.data.server\.insecure}' 2>/dev/null || true)"
if [[ "$current" != "true" ]]; then
  kubectl -n "$ARGOCD_NAMESPACE" patch configmap argocd-cmd-params-cm \
    --type merge -p '{"data":{"server.insecure":"true"}}'
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart deployment/argocd-server
fi

# Expose the UI on the node port that kind maps to localhost:8080.
kubectl -n "$ARGOCD_NAMESPACE" patch service argocd-server -p \
  '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"nodePort":30080}]}}' >/dev/null

kubectl -n "$ARGOCD_NAMESPACE" rollout status deployment/argocd-server --timeout=300s
kubectl wait --for=condition=Established crd/applications.argoproj.io --timeout=60s

log "metrics-server $METRICS_SERVER_VERSION (CPU metrics for the api autoscaler)"
kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml" >/dev/null
# kind's kubelets use self-signed certificates.
if ! kubectl -n kube-system get deployment metrics-server \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | grep -q -- '--kubelet-insecure-tls'; then
  kubectl -n kube-system patch deployment metrics-server --type=json \
    -p '[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi
kubectl -n kube-system rollout status deployment/metrics-server --timeout=180s

log "Demo Application"
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
  echo "  password: (initial secret not found; the password was changed after install)"
fi

log "Ready"
echo "  Argo CD UI: http://localhost:$UI_PORT"
echo "  Demo app:   http://localhost:$APP_PORT"
