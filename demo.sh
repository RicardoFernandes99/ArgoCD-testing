#!/usr/bin/env bash
# One entry point for the whole demo. Run ./demo.sh with no arguments for help.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

APP="demo-app"
NS="demo"
BRANCH="main"
UI_URL="http://localhost:8080"
APP_URL="http://localhost:8081"
BREAK_PREFIX="demo: break"

# ---------------------------------------------------------------- helpers ----

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✘\033[0m %s\n' "$*" >&2; exit 1; }

repo_url() {
  git remote get-url origin | sed -E 's#^git@github.com:#https://github.com/#; s#\.git$##'
}

app_field() {
  kubectl -n argocd get application "$APP" -o jsonpath="$1" 2>/dev/null || true
}

refresh() {
  kubectl -n argocd annotate application "$APP" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

require_cluster() {
  kubectl get --raw /readyz --request-timeout=5s >/dev/null 2>&1 ||
    die "The cluster is not running. Start it with: ./demo.sh up"
}

require_clean_tree() {
  [[ -z "$(git status --porcelain --untracked-files=no)" ]] ||
    die "You have uncommitted changes. Commit or stash them first."
}

sync_with_github() {
  info "Updating local $BRANCH from GitHub"
  git pull --rebase --quiet origin "$BRANCH"
}

# Push; if this container has no GitHub credentials, wait for the user to push
# from another terminal (the repo folder is shared with the host).
push() {
  info "Pushing to GitHub"
  if GIT_TERMINAL_PROMPT=0 git push --quiet origin "HEAD:$BRANCH" 2>/dev/null; then
    ok "Pushed $(git rev-parse --short HEAD)"
    return
  fi
  warn "git push failed here (no GitHub credentials in this terminal?)."
  warn "Run 'git push' from another terminal in this repo; waiting for GitHub..."
  local head; head="$(git rev-parse HEAD)"
  for _ in $(seq 1 200); do
    [[ "$(git ls-remote origin "refs/heads/$BRANCH" | cut -f1)" == "$head" ]] && {
      ok "GitHub has $(git rev-parse --short HEAD)"; return; }
    sleep 3
  done
  die "Timed out waiting for the push."
}

# Wait until GitHub Actions has committed "Deploy <component> ..." after <sha>.
wait_for_ci_deploy() {
  local component="$1" after="$2"
  info "Waiting for GitHub Actions to build and deploy '$component'"
  echo "    Watch it live: $(repo_url)/actions"
  for _ in $(seq 1 120); do
    git fetch --quiet origin "$BRANCH"
    if git log --format=%s "$after..origin/$BRANCH" | grep "^Deploy $component " >/dev/null; then
      git pull --rebase --quiet origin "$BRANCH"
      ok "CI committed: $(git log -1 --format=%s)"
      return
    fi
    sleep 5
  done
  die "No deploy commit after 10 minutes. Check $(repo_url)/actions"
}

# Refresh Argo CD and print every status change until the app reaches
# Synced/<health> on the current local HEAD.
watch_app() {
  local want_health="$1" timeout="${2:-240}"
  local head; head="$(git rev-parse HEAD)"
  local start=$SECONDS last=""
  info "Argo CD: waiting for Synced/$want_health on $(git rev-parse --short HEAD)"
  refresh
  while (( SECONDS - start < timeout )); do
    local sync health rev now
    sync="$(app_field '{.status.sync.status}')"
    health="$(app_field '{.status.health.status}')"
    rev="$(app_field '{.status.sync.revision}')"
    now="$sync/$health @ ${rev:0:7}"
    if [[ "$now" != "$last" ]]; then
      printf '    t+%3ss  %s\n' "$((SECONDS - start))" "$now"
      last="$now"
    fi
    if [[ "$rev" == "$head" && "$sync" == "Synced" && "$health" == "$want_health" ]]; then
      return 0
    fi
    (( (SECONDS - start) % 30 == 29 )) && refresh
    sleep 2
  done
  warn "Timed out after ${timeout}s. Current state: $last"
  return 1
}

active_break() {
  local sha
  sha="$(git log -1 --format=%H --grep="^$BREAK_PREFIX" "$BRANCH" || true)"
  [[ -n "$sha" ]] || return 0
  git log --format=%B "$BRANCH" | grep "This reverts commit $sha" >/dev/null || echo "$sha"
}

# --------------------------------------------------------------- commands ----

cmd_up() {
  bash scripts/bootstrap.sh
  echo
  watch_app Healthy 300 || true
  echo
  cmd_status
}

cmd_status() {
  require_cluster
  bold "Argo CD application '$APP'"
  printf '  sync/health: %s/%s\n' "$(app_field '{.status.sync.status}')" "$(app_field '{.status.health.status}')"
  local rev; rev="$(app_field '{.status.sync.revision}')"
  printf '  revision:    %s  %s\n' "${rev:0:7}" "$(git log -1 --format=%s "$rev" 2>/dev/null || echo '(run git pull to see the message)')"
  echo
  bold "Deployments"
  kubectl -n "$NS" get deploy -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,WANTED:.spec.replicas,IMAGE:.spec.template.spec.containers[0].image'
  echo
  bold "Pods"
  kubectl -n "$NS" get pods
  echo
  bold "Autoscaler"
  kubectl -n "$NS" get hpa
  echo
  local broken; broken="$(active_break)"
  [[ -n "$broken" ]] && warn "Active break: $(git log -1 --format=%s "$broken")  ->  run ./demo.sh fix"
  echo "  Argo CD UI: $UI_URL    Demo app: $APP_URL"
}

cmd_break() {
  local kind="${1:-}"
  [[ "$kind" == "deploy" || "$kind" == "code" ]] || die "Usage: ./demo.sh break deploy|code"
  require_cluster
  require_clean_tree
  sync_with_github
  [[ -z "$(active_break)" ]] || die "Already broken. Run ./demo.sh fix first."

  if [[ "$kind" == "deploy" ]]; then
    bold "Breaking the deploy: web image tag that does not exist"
    sed -i -E 's|(argocd-demo-web):.*|\1:sha-doesnotexist|' app/web.yaml
    git commit --quiet -am "$BREAK_PREFIX deploy (web image tag does not exist)"
    git --no-pager show --stat --format='  %h %s' HEAD
    push
    echo
    echo "Expect: new web pods in ErrImagePull, old ones keep serving, app Degraded after ~60 s."
    watch_app Degraded 180 || true
  else
    bold "Breaking the code: api crashes on start"
    sed -i 's|^const os = require("node:os");|&\nthrow new Error("Simulated bug: api crashes on start"); // demo: break code|' src/api/server.js
    git commit --quiet -am "$BREAK_PREFIX code (api crashes on start)"
    git --no-pager show --stat --format='  %h %s' HEAD
    local broke; broke="$(git rev-parse HEAD)"
    push
    echo
    echo "CI builds and deploys it fine (it is valid code); the new api pods then crash."
    wait_for_ci_deploy api "$broke"
    echo
    echo "Expect: new api pods in CrashLoopBackOff, old ones keep serving, app Degraded after ~60 s."
    watch_app Degraded 180 || true
  fi
  echo
  kubectl -n "$NS" get pods
  echo
  ok "Broken. Old pods still serve $APP_URL. Fix it with: ./demo.sh fix"
}

cmd_fix() {
  require_cluster
  require_clean_tree
  sync_with_github
  local sha; sha="$(active_break)"
  [[ -n "$sha" ]] || die "Nothing to fix: no active '$BREAK_PREFIX ...' commit."
  local subject; subject="$(git log -1 --format=%s "$sha")"
  bold "Fixing via Git: git revert $(git rev-parse --short "$sha") ($subject)"
  git revert --no-edit "$sha" >/dev/null
  git --no-pager show --stat --format='  %h %s' HEAD
  local fixed; fixed="$(git rev-parse HEAD)"
  push
  if [[ "$subject" == *"code"* ]]; then
    echo
    wait_for_ci_deploy api "$fixed"
  fi
  echo
  watch_app Healthy 240
  echo
  kubectl -n "$NS" get pods
  echo
  ok "Fixed. The whole incident is in git log."
}

cmd_load() {
  local seconds="${1:-60}"
  require_cluster
  bold "Load test: 6 parallel clients on /api/work for ${seconds}s (each call burns ~100 ms CPU)"
  echo "  (or use the 'Generate load' button on $APP_URL)"
  kubectl -n "$NS" delete pod loadgen --ignore-not-found --wait=true >/dev/null
  kubectl -n "$NS" run loadgen --image=curlimages/curl --restart=Never --quiet --command -- \
    sh -c "end=\$((\$(date +%s)+$seconds)); for w in 1 2 3 4 5 6; do (while [ \$(date +%s) -lt \$end ]; do curl -s -o /dev/null http://api:8080/api/work; done) & done; wait" >/dev/null
  local start=$SECONDS total=$((seconds + 60))
  printf '\n  %6s  %-16s %s\n' "time" "cpu (target)" "api pods"
  while (( SECONDS - start < total )); do
    local line
    line="$(kubectl -n "$NS" get hpa api --no-headers 2>/dev/null | awk '{print $4, $7}')"
    local phase="load"; (( SECONDS - start >= seconds )) && phase="cool-down"
    printf '  %5ss  %-16s %s   (%s)\n' "$((SECONDS - start))" "${line% *}" "${line##* }" "$phase"
    sleep 5
  done
  kubectl -n "$NS" delete pod loadgen --ignore-not-found --wait=false >/dev/null
  echo
  ok "Done. The HPA keeps scaling down toward 2 pods over the next minute."
}

cmd_down() {
  info "Deleting the kind cluster (Git keeps everything; ./demo.sh up rebuilds it)"
  kind delete cluster --name argo-poc
}

usage() {
  cat <<EOF
Usage: ./demo.sh <command>

  up              Start (or repair) the cluster, Argo CD and the app
  status          Argo CD sync/health, deployments, pods, autoscaler
  break deploy    Commit + push a web image tag that does not exist
  break code      Commit + push an api change that crashes on start (goes through CI)
  fix             git revert the active break, push, wait until Healthy again
  load [seconds]  Load test the api (default 60 s) and watch it autoscale
  refresh         Make Argo CD check GitHub now
  down            Delete the cluster

Argo CD UI: $UI_URL    Demo app: $APP_URL
EOF
}

case "${1:-}" in
  up)      cmd_up ;;
  status)  cmd_status ;;
  break)   cmd_break "${2:-}" ;;
  fix)     cmd_fix ;;
  load)    cmd_load "${2:-60}" ;;
  refresh) require_cluster; refresh; ok "Argo CD is checking GitHub now." ;;
  down)    cmd_down ;;
  *)       usage ;;
esac
