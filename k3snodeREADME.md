# k3s Node (CI) — AMP Generic module template

Turns a remote AMP host into a k3s **agent** node dedicated to pinned CI
workloads. The node runs as a privileged Docker container that AMP supervises:
start/stop maps to node up/down, k3s logs land in the AMP console, and Update
pulls a new image.

Built for one job — a `gitea/act_runner` pinned to this node so CI builds run on
datacenter hardware instead of the homelab. See `k3snodegitea-runner.example.yaml`.

## How it reaches the cluster

The AMP host is remote. It joins the tailnet with plain `tailscaled`, and the
in-cluster subnet router (`flux/apps/tailscale`) already advertises
`10.43.0.0/16,192.168.2.0/24`, so the agent reaches `k8s-control` at its LAN
address. Nothing Tailscale-specific runs inside the node container, and the
existing cluster nodes need no changes.

### What does not work, by design

Routing is one-way: your LAN nodes have no route back to `100.64.0.0/10`.

- **No `kubectl logs`, `exec`, `port-forward`, or `top` against this node.** The
  apiserver dials the kubelet on port 10250 and cannot reach it. Read CI job
  output in the Gitea UI instead.
- **No pod-to-pod networking off this node.** The pod CIDR is not advertised,
  and flannel VXLAN needs a bidirectional path. Anything scheduled here must be
  egress-only.
- **No cluster DNS.** CoreDNS's ClusterIP DNATs to a pod on the unreachable pod
  CIDR. Pinned pods need `dnsPolicy: None` with an explicit nameserver, which is
  what your existing runners already do.
- **The node still reports `Ready`** regardless, because that comes from the
  node's own outbound heartbeat. Do not read it as "networking is fine".

The default `dedicated=ci:NoSchedule` taint is what keeps this from biting: only
workloads that explicitly tolerate it can land here.

If you later want full cluster membership, that is when you give every node
Tailscale and `--vpn-auth`, per the
[k3s multicloud docs](https://docs.k3s.io/networking/distributed-multicloud).

## Security

**Set `--node-ip` before starting.** With `--net host` the agent otherwise
registers the host's **public** IP and binds the kubelet to `0.0.0.0:10250`,
exposing it to the internet. Put the host's Tailscale IPv4 in Extra Agent
Arguments:

```
--node-ip=100.x.y.z --kubelet-arg=address=100.x.y.z
```

`tailscale ip -4` prints it, and the Update preflight echoes it for you. The
preflight fails loudly while the `TAILSCALE_IP` placeholder is still in place.

Beyond that: [k3s in Docker requires `--privileged`](https://docs.k3s.io/advanced#running-k3s-in-docker),
the AMP user must be in the `docker` group, and the docker socket passthrough
gives pods on this node full control of the host's daemon. All three are
root-equivalent. Anyone with AMP admin on this box has root on it, and this box
has a tailnet route into your homelab LAN. Do not run other people's workloads
on this AMP instance.

## Resource limits — read before relying on them

`--cpus`, `--memory` and `--pids-limit` bound the **node container**: kubelet,
containerd, and pods that stay inside it.

They do **not** bound CI jobs. `act_runner` launches job containers as siblings
on the host's docker daemon, outside this cgroup — the same caveat your
`runner-w02` configmap already notes. Throttle builds with `container.options`
in the runner config, sized to the AMP host rather than to the node container.

## Caching — what makes the remote node actually fast

The link between the datacenter and `git.frostbyte.us` is the bottleneck, not
CPU. Three caches sit on the runner's PVC and survive across jobs:

**Docker layers, for free.** Job containers are siblings on the AMP host's
long-lived daemon, so its image and build cache persist between jobs. This is
the one real upside of the socket passthrough. Note the example runner sets
`force_pull: false` — the opposite of `runner-w02`, which is correct there
(LAN registry) and wrong here.

**Git objects, via a persistent bare mirror.** `actions/checkout` re-clones from
scratch every job. `k3snodecheckout.example.yaml` keeps a `--mirror` clone at
`/data/git-mirror` and clones against it with `git clone --reference`, so each
job transfers only the objects the mirror lacks — an incremental fetch, not a
full clone. Only the first job on a new repo pays for the whole history.
Requires `container.valid_volumes` plus a `-v` in `container.options`; both are
in the example config. Mind the `flock`: `capacity: 2` means concurrent fetches
into one mirror, which corrupts refs without it.

**Dependencies, via the built-in cache server.** `cache.enabled: true` with
`cache.dir` on the PVC makes `actions/cache` work for cargo registries,
`node_modules`, Go module cache. Usually a bigger win than the git objects.

One topology gotcha: the cache server must be reachable **from job containers**,
which live on the host's docker bridge while the runner is a pod. The example
sets `hostNetwork: true` on the runner and `cache.host: 172.17.0.1`. Verify that
gateway against `docker network inspect bridge` on the AMP host — if your
`docker0` subnet differs, that address is wrong and `actions/cache` will hang
rather than fail cleanly.

With all three warm, ongoing pulls from home are small deltas, and the earlier
concern about saturating your upload link mostly goes away. The first build of
each repo, and any `docker pull` of a base image not yet on the host, still pay
full freight.

## Host prerequisites

The AMP instance runs bare-metal, not in one of AMP's own instance containers —
AMP's container deployment cannot pass `--privileged`, `--net host`, or
resource caps.

### 1. Secrets file

Keeps the join token out of AMP's config database and out of `ps` output;
`run-node.sh` passes it to Docker with `--env-file`.

```bash
sudo install -d -m 0750 -o root -g amp /etc/amp-k3s
echo "K3S_TOKEN=<contents of /var/lib/rancher/k3s/server/node-token>" \
  | sudo tee /etc/amp-k3s/secrets.env >/dev/null
sudo chown root:amp /etc/amp-k3s/secrets.env && sudo chmod 0640 /etc/amp-k3s/secrets.env
```

Adjust `amp` if your AMP service user differs — check `ps -o user= -C ampinstmgr`.

### 2. Docker access

```bash
sudo usermod -aG docker amp
sudo systemctl restart ampinstmgr   # AMP must restart to pick up the new group
```

### 3. Tailscale on the host

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --accept-routes --hostname=k3s-worker-amp
tailscale ip -4    # note this for Extra Agent Arguments
```

`--accept-routes` is what pulls in the subnet router's `192.168.2.0/24`.

## Setup

Add this repository to AMP's template sources and create a **k3s Node (CI)**
instance. Set Control Plane URL, Node Name, and Extra Agent Arguments (replacing
`TAILSCALE_IP`). Run **Update** — the preflight reports missing prerequisites
and checks that the control plane answers — then Start.

Once the node registers, copy `k3snodegitea-runner.example.yaml` into
`flux/apps/gitea-runner/`, adjust `nodeSelector` to your Node Name, and add it
to that directory's `kustomization.yaml`.

## Files

| File | Role |
|---|---|
| `k3snode.kvp` | template root — executable, env vars, console regexes |
| `k3snodeconfig.json` | the settings UI |
| `k3snodeports.json` | kubelet / flannel ports, for AMP's bookkeeping |
| `k3snodeupdates.json` | update stages: fetch launcher, preflight, pull image |
| `k3snodemetaconfig.json` | unused — settings reach the node as env vars |
| `k3snoderun.sh` | AMP-side launcher; supervises `docker run` in the foreground |
| `k3snodegitea-runner.example.yaml` | example pinned runner, for the flux repo |
| `k3snodecheckout.example.yaml` | example workflow: mirror-backed incremental checkout |

## Not yet verified

None of this has been run. Untested in particular: whether `docker stop` unwinds
the privileged container's mounts cleanly on that kernel, whether local-path
PVCs behave inside the node container's named volume, how much the flannel
VXLAN peering failures to unreachable LAN nodes pollute the AMP console, and
whether job containers on the docker bridge can reach the cache server on a
hostNetwork pod at 172.17.0.1.
