# GitOps with Argo CD: a minimal proof of concept

One app (a web front end + an API), one local Kubernetes cluster, one Git repository.
Argo CD watches this repository and keeps the cluster in sync with it.

Everything runs inside a **dev container**. The only thing you need on your
machine is Docker (or nothing at all, if you use GitHub Codespaces).

```
.devcontainer/devcontainer.json   Dev container: Ubuntu + Docker-in-Docker + kubectl
scripts/install-tools.sh          Installs kind and the argocd CLI (runs automatically)
scripts/bootstrap.sh              Creates the cluster, installs Argo CD, registers the app
app/web.yaml                      web: Deployment + Service (nginx, serves the page, proxies /api)
app/api.yaml                      api: Deployment + Service (Node.js JSON API)
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
                                              │ 1. fetch (every ~3 min, or on Refresh)
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
> `repoURL` to your fork. You need push access for steps 2 and 4.

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

## 4. Bootstrap: cluster + Argo CD + Application

```bash
./scripts/bootstrap.sh
```

The script is **idempotent**, so you can run it again at any time. It:

1. creates the kind cluster `argo-poc` (if it does not exist yet);
2. installs Argo CD from the official `stable` manifest (`kubectl apply --server-side`);
3. sets the Argo CD server to plain HTTP, so the UI works behind the port-forward
   without certificate errors (fine for a local POC; **not** for production);
4. waits for `argocd-server` to be ready;
5. applies `application.yaml`;
6. prints the **initial `admin` password** (it is never written to the repository);
7. exposes the UI on port **8080** (`kubectl port-forward`). This step stays in
   the foreground, so **leave this terminal open** and open a new one for the demo.

The first run takes about 3 to 5 minutes (it downloads the node image and the
Argo CD images).

### Opening the UI and logging in

- **VS Code locally:** open <http://localhost:8080> (the port is forwarded automatically).
- **Codespaces:** **Ports** tab → port **8080** ("Argo CD UI") → globe icon.

Log in with **username `admin`** and the password printed by the script.
If you lost it:

```bash
argocd admin initial-password -n argocd
```

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
 browser ──▶ web (nginx, 2 pods) ──/api/──▶ api (Node.js, 2 pods)
             serves the page                returns { message, version, pod }
```

- **web** serves the page and forwards `/api/*` to the `api` Service inside the
  cluster. The browser only ever talks to `web`.
- **api** answers `GET /api/info` with its message, its version and the name
  of the pod that answered.
- Each one has its own source folder (`src/web`, `src/api`), image, manifest
  (`app/web.yaml`, `app/api.yaml`) and CI workflow, so they are built and
  deployed **independently**. Argo CD manages both from the same `app/` folder.

Open a **second terminal** in the dev container for the commands below.
These make the demo easier to follow:

```bash
# Watch the pods live (third terminal, or split the terminal)
kubectl get pods -n demo -w
```

```bash
# Ask Argo CD to check Git now instead of waiting for the next poll (~3 min)
kubectl -n argocd annotate application demo-app argocd.argoproj.io/refresh=normal --overwrite
```

The **REFRESH** button in the UI does the same thing.

```bash
# Open the app on port 8081 (another terminal; leave it running)
kubectl port-forward --address 0.0.0.0 -n demo svc/web 8081:80
```

> **Restart the port-forward after a rollout of `web`.** `kubectl port-forward`
> attaches to a single pod, so it stops working when that pod is replaced. Stop
> it with Ctrl+C and run the same command again.

### Step 1: initial sync

As soon as `bootstrap.sh` applies `application.yaml`, Argo CD clones the repo
and creates both Deployments and both Services.

```bash
kubectl -n argocd get application demo-app
kubectl get deploy,svc,pods -n demo
```

Expected: `SYNC STATUS = Synced`, `HEALTH STATUS = Healthy`, and **4 pods**
`Running` (2 `web`, 2 `api`). In the UI, click the `demo-app` tile to see the
resource tree (Application → Services / Deployments → ReplicaSets → Pods).

Open <http://localhost:8081> (or port **8081** in the Codespaces Ports tab).
The page shows the **web** and **api** versions (the commit each image was built
from) and the API pod that answered. Click **Call the API again** a few times:
the pod name changes as the `api` Service spreads requests across its pods.

### Step 2: change in Git → change in the cluster (api: 2 → 4 replicas)

```bash
git pull
sed -i 's/replicas: 2/replicas: 4/' app/api.yaml
git diff
git commit -am "Scale api to 4 replicas"
git push
```

Click **REFRESH** (or use the `annotate` command above). Argo CD detects the new
commit, briefly marks the app `OutOfSync`, syncs it, and **2 new `api` pods**
appear. `web` is untouched.

```bash
kubectl get deploy -n demo   # api READY 4/4, web 2/2
```

In the UI, the app's **commit/revision** is now the hash of your commit.
**Call the API again** now shows up to 4 different pod names.

### Step 3: drift in the cluster → self-heal

Someone changes the cluster by hand, going around Git:

```bash
kubectl scale deploy/api -n demo --replicas=1
kubectl get deploy api -n demo -w
```

Within a few seconds Argo CD detects the drift (`OutOfSync`) and, because of
`selfHeal: true`, puts it back to **4 replicas**: Git wins. Press Ctrl+C to stop
watching.

### Step 4: a bad change → failure → recovery via Git

Push a `web` image tag that does not exist:

```bash
sed -i -E 's|(argocd-demo-web):.*|\1:sha-doesnotexist|' app/web.yaml
git commit -am "Break the web image tag"
git push
kubectl -n argocd annotate application demo-app argocd.argoproj.io/refresh=normal --overwrite
```

What happens:

- The new `web` pods get stuck in `ErrImagePull` / `ImagePullBackOff`.
- The **old `web` pods keep running**: the RollingUpdate does not remove healthy
  pods while the new ones are not ready, so the page still works on port 8081.
  `api` is not affected at all.
- After about **60 s** (`progressDeadlineSeconds: 60`) the app turns
  **`Degraded`** in the UI, and the tree shows exactly which Deployment is broken.
  Note that it is still `Synced`: the cluster does exactly what Git says.
  **Git** is what is wrong.

```bash
kubectl get pods -n demo
kubectl -n argocd get application demo-app
```

Recovery is a Git operation, not a `kubectl` one:

```bash
git revert --no-edit HEAD
git push
kubectl -n argocd annotate application demo-app argocd.argoproj.io/refresh=normal --overwrite
```

Argo CD applies the revert, the broken pods disappear, and the app goes back to
**`Healthy`**. The whole incident (break + fix) is in the `git log`.

### Step 5: code change → CI → Argo CD (the full loop)

Steps 1 to 4 change the **manifests** by hand. In practice, developers change
**code**, and a pipeline turns that into a new image and a manifest change.
Each service has a workflow ([`api.yaml`](.github/workflows/api.yaml),
[`web.yaml`](.github/workflows/web.yaml)) that runs only when its own `src/`
folder changes, and both use the same
[`build-and-deploy.yaml`](.github/workflows/build-and-deploy.yaml):

```
 edit src/api ──push──▶  GitHub Actions ("api" workflow)          Argo CD
                         1. build image from src/api              (in the cluster)
                         2. push ghcr.io/<owner>/argocd-demo-api:sha-<commit>
                         3. commit new tag to app/api.yaml ──────▶ sees the commit,
                                                                   rolls out api only
```

The two halves have separate responsibilities:

- **CI (GitHub Actions)** builds and publishes artifacts, then *proposes* the
  new desired state by committing to Git. It has **no access to the cluster**.
- **CD (Argo CD)** is the only thing that changes the cluster, and only to match Git.

Change the API's message and push:

```bash
git pull
sed -i 's/Hello from the API"/Hello from the API, v2"/' src/api/server.js
git commit -am "Change the API message"
git push
```

Then:

1. In GitHub, open the **Actions** tab: only the **api** workflow runs (about 1 minute).
2. When it finishes, there is a new commit on `main` by `github-actions[bot]`:
   **"Deploy api sha-xxxxxxx"**. Pull it locally: `git pull`.
3. Refresh Argo CD (or wait for the poll). Only the `api` Deployment rolls out.
4. Click **Call the API again** on <http://localhost:8081>. The **api** card
   shows the new message and version, and the **web** version did not change.
   (No port-forward restart needed: only `api` pods were replaced.)

```bash
kubectl get deploy -n demo -o custom-columns=NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image
```

To roll back, `git revert` the **"Deploy api ..."** commit (the previous image
is still in GHCR), exactly as in step 4.

> **The images must be public.** The kind cluster has no registry credentials.
> The packages are created public here, because each Dockerfile links its image
> to this public repository (`org.opencontainers.image.source`). If your pods
> show `ImagePullBackOff` with `403`/`unauthorized`, make the package public
> yourself: GitHub profile → **Packages** → `argocd-demo-api` / `argocd-demo-web`
> → **Package settings** → **Change visibility → Public**.
>
> **Always `git pull` before editing.** The workflows push commits to `main`,
> so your local branch falls behind after each run.

### Resetting for another run

```bash
git pull
sed -i 's/replicas: 4/replicas: 2/' app/api.yaml
git commit -am "Reset api to 2 replicas" && git push
```

---

## 6. Troubleshooting

| Symptom | Cause / fix |
|---------|-------------|
| `kind create cluster` fails at **"Starting control-plane"** and the kubelet logs mention cgroups | The Docker host uses **cgroup v1** (common with Docker Desktop on older WSL2 setups). `bootstrap.sh` detects this and sets `failCgroupV1: false`, but nested cgroup v1 is still fragile: it often fails after a cluster has been deleted and recreated. Quick fix: **rebuild/restart the dev container** (F1 → "Dev Containers: Rebuild Container") and run `bootstrap.sh` again. Permanent fix on Windows: switch WSL2 to cgroup v2. Add `kernelCommandLine = cgroup_no_v1=all` under `[wsl2]` in `%USERPROFILE%\.wslconfig`, run `wsl --shutdown` and restart Docker Desktop. Check with `docker info \| grep -i cgroup`, which should show `Cgroup Version: 2`. |
| App stays `Unknown` with **"remote repository is empty"** or **"repository not found"** | `repoURL` in `application.yaml` points to a repo that is empty, private or wrong. Push to `main` first; for a fork, change `repoURL` and run `kubectl apply -f application.yaml`. |
| I pushed, but nothing changes | Argo CD polls Git every ~3 minutes. Click **REFRESH** or use the `annotate ... refresh=normal` command. Check that you pushed to `main`. |
| `bind: address already in use` on port 8080 | A previous port-forward is still running. `pkill -f "port-forward"` and then run `./scripts/bootstrap.sh` again. |
| The UI stopped responding | The port-forward ends if the `argocd-server` pod restarts. Run `./scripts/bootstrap.sh` again (it is idempotent). |
| `git push` asks for credentials in the dev container | In Codespaces this works automatically. Locally, the Dev Containers extension reuses your host's Git credentials. Make sure `git push` works on the host first. |
| After a CI deploy, pods are in **`ImagePullBackOff`** with `403`/`unauthorized` | The GHCR package is private. Make it public (see step 5). The old pods keep serving until the new ones can pull. |
| Page loads but the **api** card says `unavailable` / `HTTP 502` | `web` cannot reach `api`. Check `kubectl get pods,endpoints -n demo` (are `api` pods Ready?) and `kubectl logs deploy/api -n demo`. |
| Page at 8081 stops loading after a deploy | The port-forward was attached to a `web` pod that was replaced. Restart the `kubectl port-forward ... svc/web 8081:80` command. |
| Workflow fails at `git push` with **403** | Repo **Settings → Actions → General → Workflow permissions** must allow the workflow to write (the workflow asks for `contents: write`). |
| `git push` rejected ("fetch first") after a CI run | The workflow pushed a "Deploy ..." commit. Run `git pull --rebase` and push again. |
| Lost the admin password | `argocd admin initial-password -n argocd` |
| Start from scratch | `kind delete cluster --name argo-poc` and then `./scripts/bootstrap.sh` |
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
kind delete cluster --name argo-poc
```

Or simply delete the Codespace or dev container.
