# GitOps with Argo CD: a minimal proof of concept

One app, one local Kubernetes cluster, one Git repository.
Argo CD watches this repository and keeps the cluster in sync with it.

Everything runs inside a **dev container**. The only thing you need on your
machine is Docker (or nothing at all, if you use GitHub Codespaces).

```
.devcontainer/devcontainer.json   Dev container: Ubuntu + Docker-in-Docker + kubectl
scripts/install-tools.sh          Installs kind and the argocd CLI (runs automatically)
scripts/bootstrap.sh              Creates the cluster, installs Argo CD, registers the app
app/deployment.yaml               The demo app: nginx, 2 replicas, namespace "demo"
app/service.yaml                  ClusterIP Service for the demo app
application.yaml                  Argo CD Application: "deploy app/ from main into demo"
src/                              Source of our own app image (Dockerfile + page)
.github/workflows/                CI: build the image, push to GHCR, update app/deployment.yaml
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

Open a **second terminal** in the dev container for the commands below.
These two make the demo easier to follow:

```bash
# Watch the pods live (third terminal, or split the terminal)
kubectl get pods -n demo -w
```

```bash
# Ask Argo CD to check Git now instead of waiting for the next poll (~3 min)
kubectl -n argocd annotate application demo-app argocd.argoproj.io/refresh=normal --overwrite
```

The **REFRESH** button in the UI does the same thing.

### Step 1: initial sync

As soon as `bootstrap.sh` applies `application.yaml`, Argo CD clones the repo
and creates the Deployment and the Service.

```bash
kubectl -n argocd get application demo-app
kubectl get deploy,svc,pods -n demo
```

Expected: `SYNC STATUS = Synced`, `HEALTH STATUS = Healthy`, and **2 pods**
`Running`. In the UI, the `demo-app` tile is green; click it to see the
resource tree (Application → Service / Deployment → ReplicaSet → Pods).

To see the app itself (optional, in another terminal):

```bash
kubectl port-forward --address 0.0.0.0 -n demo svc/demo-app 8081:80
```

Then open <http://localhost:8081> (or port **8081** in the Codespaces Ports tab):
you get the "Welcome to nginx!" page.

### Step 2: change in Git → change in the cluster (2 → 4 replicas)

```bash
sed -i 's/replicas: 2/replicas: 4/' app/deployment.yaml
git diff
git commit -am "Scale demo-app to 4 replicas"
git push
```

Click **REFRESH** (or use the `annotate` command above). Argo CD detects the new
commit, briefly marks the app `OutOfSync`, syncs it, and **2 new pods** appear.

```bash
kubectl get deploy demo-app -n demo   # READY 4/4
```

In the UI, the app's **commit/revision** is now the hash of your commit.

### Step 3: drift in the cluster → self-heal

Someone changes the cluster by hand, going around Git:

```bash
kubectl scale deploy/demo-app -n demo --replicas=1
kubectl get deploy demo-app -n demo -w
```

Within a few seconds Argo CD detects the drift (`OutOfSync`) and, because of
`selfHeal: true`, puts it back to **4 replicas**: Git wins. Press Ctrl+C to stop
watching.

### Step 4: a bad change → failure → recovery via Git

Push an image tag that does not exist:

```bash
sed -i 's|image: nginx:1.27-alpine|image: nginx:1.27-doesnotexist|' app/deployment.yaml
git commit -am "Break the image tag"
git push
kubectl -n argocd annotate application demo-app argocd.argoproj.io/refresh=normal --overwrite
```

What happens:

- The new pods get stuck in `ErrImagePull` / `ImagePullBackOff`.
- The **old pods keep running**: the RollingUpdate does not remove healthy pods
  while the new ones are not ready, so the app keeps responding on port 8081.
- After about **60 s** (`progressDeadlineSeconds: 60` in the Deployment) the app
  turns **`Degraded`** in the UI. Note that it is still `Synced`: the cluster
  does exactly what Git says. **Git** is what is wrong.

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
The workflow in [`.github/workflows/build-and-deploy.yaml`](.github/workflows/build-and-deploy.yaml)
does exactly that, on every push to `main` that touches `src/`:

```
 edit src/  ──push──▶  GitHub Actions                      Argo CD
                       1. build image from src/            (in the cluster)
                       2. push ghcr.io/<owner>/argocd-demo-app:sha-<commit>
                       3. commit new tag to app/deployment.yaml ──▶ sees the commit,
                                                                    rolls out the new image
```

The two halves have separate responsibilities:

- **CI (GitHub Actions)** builds and publishes artifacts, then *proposes* the
  new desired state by committing to Git. It has **no access to the cluster**.
- **CD (Argo CD)** is the only thing that changes the cluster, and only to match Git.

Change the page and push:

```bash
sed -i 's/Hello from GitOps!/Hello from GitOps, v2!/' src/index.html
git commit -am "Change the greeting"
git push
```

Then:

1. In GitHub, open the **Actions** tab and watch **Build and deploy** (about 1 to 2 minutes).
2. When it finishes, there is a new commit on `main` by `github-actions[bot]`:
   **"Deploy demo-app sha-xxxxxxx"**. Pull it locally: `git pull`.
3. Refresh Argo CD (or wait for the poll). The Deployment rolls out the new image.
4. Open <http://localhost:8081>. The page shows the new text and
   `version: sha-xxxxxxx`, the commit it was built from.

```bash
kubectl get deploy demo-app -n demo -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

To roll back, `git revert` the **"Deploy demo-app ..."** commit (the
previous image is still in GHCR), exactly as in step 4.

> **One-time setup: make the image public.** Images pushed to GHCR are
> **private** by default, and the kind cluster has no credentials to pull them
> (pods would end up in `ImagePullBackOff`). After the first workflow run:
> GitHub profile → **Packages** → `argocd-demo-app` → **Package settings** →
> **Change visibility → Public**.
>
> **Always `git pull` before editing.** The workflow pushes commits to `main`,
> so your local branch falls behind after each run.

### Resetting for another run

```bash
sed -i 's/replicas: 4/replicas: 2/' app/deployment.yaml
git commit -am "Reset demo-app to 2 replicas" && git push
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
| After a CI deploy, pods are in **`ImagePullBackOff`** with `403`/`unauthorized` | The GHCR package is still private. Make it public (see step 5). The old pods keep serving until the new ones can pull. |
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
