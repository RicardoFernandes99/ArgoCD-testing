# GitOps with Argo CD: a minimal proof of concept

One app (a web front end + an API), one local Kubernetes cluster, one Git repository.
Argo CD watches this repository and keeps the cluster in sync with it.

Everything runs inside a **dev container**. The only thing you need on your
machine is Docker (or nothing at all, if you use GitHub Codespaces).

```
.devcontainer/devcontainer.json   Dev container: Ubuntu + Docker-in-Docker + kubectl
scripts/install-tools.sh          Installs kind and the argocd CLI (runs automatically)
demo.sh                           One command for everything: up, status, break, fix, load, down
scripts/bootstrap.sh              Creates/repairs the cluster, installs Argo CD, registers the app
app/web.yaml                      web: Deployment + Service (nginx, serves the page, proxies /api)
app/api.yaml                      api: Deployment + Service + autoscaler (Node.js JSON API)
application.yaml                  Argo CD Application: "deploy app/ from main into demo"
src/web/, src/api/                Source of the two images (Dockerfile + code)
.github/workflows/                CI: build each image, push to GHCR, update its manifest in app/
```

---

## 1. What is GitOps?

**GitOps** is a way of operating infrastructure and applications where **Git is
the single source of truth** for the desired state of the system.

- The desired state is **declarative** (Kubernetes YAML manifests).
- It is **versioned** in Git: every change is a commit, with history, review and
  an easy rollback (`git revert`).
- It is **pulled automatically**: an agent running *inside* the cluster
  (here, Argo CD) fetches the state from Git. Nobody runs `kubectl apply` by hand,
  and no CI pipeline needs credentials to the cluster.
- It is **continuously reconciled**: the agent keeps comparing Git with the
  cluster and corrects any difference.

### The reconciliation loop

```
        ┌──────────────┐   git push    ┌──────────────┐
        │  Developer   │ ────────────▶ │  Git (main)  │  desired state
        └──────────────┘               └──────┬───────┘
                                              │ 1. fetch (every ~3 min, or on refresh)
                                              ▼
                                       ┌──────────────┐
                                       │   Argo CD    │ 2. diff: desired vs. live
                                       └──────┬───────┘
                                              │ 3. sync: apply the difference
                                              ▼
                                       ┌──────────────┐
                                       │  Kubernetes  │  live state
                                       └──────────────┘
                                              │ 4. watch for changes (drift)
                                              └──────▶ back to 2
```

Argo CD reports two independent statuses for each Application:

| Status | Values | Question it answers |
|--------|--------|---------------------|
| **Sync** | `Synced` / `OutOfSync` | Does the cluster match Git? |
| **Health** | `Healthy` / `Progressing` / `Degraded` / ... | Are the resources actually working? |

Our `application.yaml` enables **automated sync** with:

- `prune: true`: resources deleted from Git are deleted from the cluster;
- `selfHeal: true`: manual changes in the cluster are reverted to what Git says;
- `CreateNamespace=true`: Argo CD creates the `demo` namespace if it is missing.

---

## 2. Prerequisites

Pick **one** of these:

| Option | What you need |
|--------|---------------|
| **GitHub Codespaces** | A GitHub account. Nothing to install. |
| **VS Code locally** | [Docker Desktop](https://www.docker.com/products/docker-desktop/) (or Docker Engine on Linux), [VS Code](https://code.visualstudio.com/) and the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers) extension. |

Resources: about **4 CPUs and 8 GB RAM** for the dev container (kind + Argo CD).

> **Your own copy.** Argo CD pulls from the URL in `application.yaml`
> (`repoURL`). To do the demo yourself, **fork** this repository and change
> `repoURL` to your fork. You need push access for the demo steps.

---

## 3. Opening the dev container

### Option A: GitHub Codespaces

1. On the repository page on GitHub: **Code → Codespaces → Create codespace on main**.
2. Wait for the build. `scripts/install-tools.sh` runs on its own (look for
   `kind version` / `argocd version` at the end of the creation log).

### Option B: VS Code + Docker

```bash
git clone https://github.com/RicardoFernandes99/ArgoCD-testing.git
code ArgoCD-testing
```

In VS Code: **F1 → "Dev Containers: Reopen in Container"**. The first build takes
a few minutes.

Check that the tools are there (in the VS Code terminal, which now runs *inside*
the container):

```bash
kind version && kubectl version --client && argocd version --client --short
```

---

## 4. Start everything: `./demo.sh up`

Everything in the demo goes through one script, [`demo.sh`](demo.sh):

```
./demo.sh up              Start (or repair) the cluster, Argo CD and the app
./demo.sh status          Argo CD sync/health, deployments, pods, autoscaler
./demo.sh break deploy    Commit + push a web image tag that does not exist
./demo.sh break code      Commit + push an api change that crashes on start (goes through CI)
./demo.sh fix             git revert the active break, push, wait until Healthy again
./demo.sh load [seconds]  Load test the api (default 60 s) and watch it autoscale
./demo.sh refresh         Make Argo CD check GitHub now
./demo.sh down            Delete the cluster
```

Start with:

```bash
./demo.sh up
```

`up` is safe to run at any time; it only does what is missing. It runs
[`scripts/bootstrap.sh`](scripts/bootstrap.sh), which:

1. creates the kind cluster `argo-poc` with **two fixed ports**, 8080 (Argo CD UI)
   and 8081 (the app). There are no `kubectl port-forward`s to keep alive;
2. if the cluster already exists but is not responding (e.g. after a restart),
   starts it again and waits for it;
3. installs Argo CD from the official `stable` manifest (`kubectl apply --server-side`)
   and serves its UI over plain HTTP (fine for a local POC; **not** for production);
4. installs **metrics-server** (CPU metrics for the `api` autoscaler, step 6);
5. applies `application.yaml`, after which **Argo CD deploys the app from Git**;
6. prints the **initial `admin` password** (it is never written to the repository).

Then `up` waits until Argo CD reports the app **Synced/Healthy** and prints the
status. The first run takes about 3 to 5 minutes; later runs take seconds.

**Stopping and starting:** just close VS Code or stop the codespace. The cluster
lives inside the dev container and survives restarts; next time, run
`./demo.sh up` again. You never need to redeploy the app by hand: whatever
happens to the cluster, Argo CD puts back what is in Git.

### Opening the UI and the app

| | VS Code locally | Codespaces |
|---|---|---|
| **Argo CD UI** | <http://localhost:8080> | **Ports** tab → 8080 → globe icon |
| **Demo app** | <http://localhost:8081> | **Ports** tab → 8081 → globe icon |

Log in to Argo CD with **username `admin`** and the password printed by `up`.
If you lost it: `argocd admin initial-password -n argocd`.

Optional, to use the `argocd` CLI as well:

```bash
argocd login localhost:8080 --username admin --plaintext
argocd app get demo-app
```

---

## 5. Demo (this is also the script for the video)

### The app

The demo app has two services, like a (very) small real application:

```
 browser ──▶ web (nginx, 2 pods) ──/api/──▶ api (Node.js, 2–8 pods)
             serves the page                returns { message, version, pod }
```

- **web** serves the page and forwards `/api/*` to the `api` Service inside the
  cluster. The browser only ever talks to `web`.
- **api** answers `GET /api/info` with its message, its version and the name of
  the pod that answered; `GET /api/work` burns CPU for the load test. An
  autoscaler adds `api` pods under load (step 6).
- Each one has its own source folder (`src/web`, `src/api`), image, manifest
  (`app/web.yaml`, `app/api.yaml`) and CI workflow, so they are built and
  deployed **independently**. Argo CD manages both from the same `app/` folder.

**Continuous deployment:** every push to `main` that changes `src/api` or
`src/web` is built by GitHub Actions and deployed by Argo CD, with no manual
step. On GitHub, each deploy shows up under the repo's **Deployments**
(environment `kind-local`) and in the **Actions** tab.

Suggested screen layout for the video: browser with the Argo CD UI and the app
side by side, plus two terminals:

```bash
kubectl get pods -n demo -w      # terminal 1: pods live
./demo.sh ...                    # terminal 2: the demo commands below
```

> Argo CD checks GitHub about every 3 minutes. The `demo.sh` commands make it
> check right away (`./demo.sh refresh`, or the **REFRESH** button in the UI,
> does the same).

### Step 1: everything in sync

```bash
./demo.sh status
```

Expected: `Synced/Healthy`, 2 `web` and 2 `api` pods, and the autoscaler at
2 replicas. In the UI, click the `demo-app` tile to see the resource tree
(Application → Services / Deployments / HPA → ReplicaSets → Pods).

Open <http://localhost:8081>. The page shows the **web** and **api** versions
(the commit each image was built from). Click **Call the API again** a few
times: the pod name changes as the `api` Service spreads requests.

### Step 2: change in Git → change in the cluster

Scale `web` from 2 to 4 pods by changing Git, not the cluster:

```bash
git pull
sed -i 's/replicas: 2/replicas: 4/' app/web.yaml
git commit -am "Scale web to 4 replicas" && git push
./demo.sh refresh
```

Argo CD detects the new commit, briefly marks the app `OutOfSync`, syncs it, and
**2 new `web` pods** appear. In the UI, the revision is now your commit.

> Why `web` and not `api`? The `api` pod count belongs to its autoscaler
> (step 6), so `app/api.yaml` deliberately has no `replicas` field.

### Step 3: drift in the cluster → self-heal

Someone changes the cluster by hand, going around Git:

```bash
kubectl scale deploy/web -n demo --replicas=1
```

Within a few seconds Argo CD detects the drift and, because of `selfHeal: true`,
puts it back to **4**: Git wins. Put it back to 2 the GitOps way:

```bash
sed -i 's/replicas: 4/replicas: 2/' app/web.yaml
git commit -am "Scale web back to 2 replicas" && git push
./demo.sh refresh
```

### Step 4: a bad deploy → failure → fix via Git

```bash
./demo.sh break deploy
```

This commits and pushes a `web` image tag that does not exist, then follows
Argo CD:

- the new `web` pods get stuck in `ErrImagePull` / `ImagePullBackOff`;
- the **old `web` pods keep running** (RollingUpdate does not remove healthy
  pods while the new ones are not ready), so the page still works;
- after about **60 s** (`progressDeadlineSeconds: 60`) the app turns
  **`Degraded`**, and the tree shows exactly which Deployment is broken. It is
  still `Synced`: the cluster does exactly what Git says. **Git** is what is wrong.

Recovery is a Git operation, not a `kubectl` one:

```bash
./demo.sh fix
```

`fix` runs `git revert` on the break commit, pushes, and waits until the app is
**Healthy** again. The whole incident (break + fix) is in `git log`.

### Step 5: broken code → CI → failure → fix via CI

```bash
./demo.sh break code
```

This time the bug is in the **code**: `src/api/server.js` throws on start.

1. GitHub Actions runs the **api** workflow (watch it in the **Actions** tab).
   The build succeeds, because the code is valid; it just crashes when run.
2. The workflow pushes **"Deploy api sha-…"**, Argo CD rolls it out, and the new
   `api` pods go into `CrashLoopBackOff`.
3. The old `api` pods keep serving, and the app turns **`Degraded`**.

```bash
./demo.sh fix
```

`fix` reverts the bad commit. CI builds and deploys the fixed code (another
**"Deploy api sha-…"**), and the app returns to **Healthy**. This is the full
continuous-deployment loop in both directions: code → CI → Git → Argo CD → cluster.

> CI never talks to the cluster. It builds the image and **commits** the new
> tag to `app/api.yaml`; Argo CD is the only thing that changes the cluster.

### Step 6: more load → more pods (autoscaling)

GitOps decides *what* runs; Kubernetes can still decide *how many*. The `api`
has a **HorizontalPodAutoscaler** (bottom of `app/api.yaml`) that keeps
**2 to 8** pods, aiming for **50 %** CPU of each pod's request (`cpu: 100m`),
and scales back down about 30 s after the load stops.

```bash
./demo.sh load        # 60 s of load from inside the cluster; prints CPU and pod count
```

Or click **Generate load (60 s)** on <http://localhost:8081>: the page lists
every `api` pod that answers, so new pods appear as they join.

- within ~30 s the CPU goes well above `50%` and the HPA adds pods;
- in the Argo CD UI the extra pods appear in the tree, and the app **stays
  Synced**: the pod count is not part of the desired state in Git (the
  Deployment has no `replicas` field, so Argo CD does not fight the HPA);
- about 30 s after the load ends, the HPA scales back down toward 2.

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `./demo.sh up` fails at **"Starting control-plane"**, or says *"The cluster failed to start"* | The Docker host uses **cgroup v1** (common with Docker Desktop on older WSL2 setups). The cluster works and survives restarts, but creating it again after deleting it fails until the dev container is restarted: **F1 → "Dev Containers: Rebuild Container"**, then `./demo.sh up`. **Permanent fix (Windows):** switch WSL2 to cgroup v2. Add `kernelCommandLine = cgroup_no_v1=all` under `[wsl2]` in `%USERPROFILE%\.wslconfig`, run `wsl --shutdown` and restart Docker Desktop. `docker info \| grep -i cgroup` should then show `Cgroup Version: 2`. |
| App stays `Unknown` with **"remote repository is empty"** or **"repository not found"** | `repoURL` in `application.yaml` points to a repo that is empty, private or wrong. For a fork, change `repoURL` and run `./demo.sh up`. |
| I pushed, but nothing changes | Argo CD polls Git every ~3 minutes: `./demo.sh refresh`. For code changes, the CI run must finish first (Actions tab). |
| `git push` fails inside the dev container | In Codespaces this works automatically. Locally, the Dev Containers extension reuses your host's Git credentials, so make sure `git push` works on the host. `demo.sh` also waits if its push fails: push from any other terminal and it continues. |
| `fatal: detected dubious ownership in repository` | Run `git config --global --add safe.directory "$PWD"` (new dev containers do this automatically). |
| After a CI deploy, pods are in **`ImagePullBackOff`** with `403`/`unauthorized` | The GHCR package is private. GitHub profile → **Packages** → `argocd-demo-api` / `argocd-demo-web` → **Package settings** → **Change visibility → Public**. |
| Page loads but the **api** card says `unavailable` / `HTTP 502` | No `api` pod is Ready. `kubectl get pods -n demo` and `kubectl logs deploy/api -n demo`. |
| Workflow fails at `git push` with **403** | Repo **Settings → Actions → General → Workflow permissions** must allow the workflow to write (the workflow asks for `contents: write`). |
| `git push` rejected ("fetch first") | A CI run pushed a "Deploy ..." commit. `git pull --rebase` and push again. |
| `kubectl get hpa` shows **`<unknown>/50%`** | metrics-server has no data yet (~30 s after pods start), or is not running. `./demo.sh up` installs it. |
| Port 8080/8081 does not open | `./demo.sh status`. If the cluster is down: `./demo.sh up`. In Codespaces, check the **Ports** tab. |
| Codespace slow or pods `Pending` | Use a machine with at least 4 cores / 8 GB (`hostRequirements` in `devcontainer.json` asks for this). |

Useful commands:

```bash
kubectl -n argocd get application demo-app -o yaml   # full status, including errors
kubectl -n argocd logs deploy/argocd-repo-server     # problems fetching Git
kubectl -n argocd logs statefulset/argocd-application-controller   # sync/diff problems
kubectl describe pod -n demo <pod>                   # why a pod does not start
```

---

## 7. Next steps

This POC is intentionally minimal. Natural next steps:

1. **Image Updater instead of CI commits.** Step 5 has CI commit the new tag.
   An alternative is [Argo CD Image Updater](https://argocd-image-updater.readthedocs.io/),
   which watches the registry and updates the tag itself.
2. **Multiple environments with Kustomize + ApplicationSet.** A `base/` plus
   `overlays/dev` and `overlays/prod` overlays (different replicas, tags and
   resources), and an **ApplicationSet** that generates one Application per
   environment automatically.
3. **Progressive delivery with Argo Rollouts.** Replace the Deployment with a
   `Rollout` using a **canary** strategy (e.g. 20% → 50% → 100% with pauses), and
   optionally automatic analysis with metrics to roll back on its own.

---

## Cleanup

```bash
./demo.sh down
```

Or simply delete the Codespace or dev container.
