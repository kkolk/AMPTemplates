#!/usr/bin/env bash
# k3s Node (CI) - AMP launcher.
#
# Runs a stock rancher/k3s agent container in the foreground so AMP's Generic
# module owns its lifecycle: AMP start/stop maps to node up/down, k3s logs land
# in the AMP console, and SIGTERM triggers `docker stop`.
#
# The node reaches the control plane over the LAN route advertised by the
# in-cluster Tailscale subnet router, so no Tailscale runs here - the AMP host's
# own tailscaled handles that, out of band.
#
# Runs as the unprivileged AMP user, which must be in the `docker` group. That
# membership is root-equivalent on this host, as is the privileged container
# itself - see k3snodeREADME.md.

set -euo pipefail

SECRETS_FILE=/etc/amp-k3s/secrets.env

log() { printf '[amp-k3s] %s\n' "$*"; }
die() { printf '[amp-k3s] FATAL: %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null || die "docker is not installed on this host"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon - is the AMP user in the 'docker' group?"

[[ -r "$SECRETS_FILE" ]] || die "$SECRETS_FILE is missing or unreadable by the AMP user (want root:amp 0640)"
[[ -n "${NODE_IMAGE:-}" ]]    || die "NODE_IMAGE not set"
[[ -n "${K3S_NODE_NAME:-}" ]] || die "K3S_NODE_NAME not set"
[[ -n "${K3S_URL:-}" ]]       || die "K3S_URL not set"

CONTAINER="amp-k3s-${K3S_NODE_NAME}"
STOP_TIMEOUT=${STOP_TIMEOUT:-60}

if docker inspect "$CONTAINER" >/dev/null 2>&1; then
    log "removing stale container $CONTAINER"
    docker rm -f "$CONTAINER" >/dev/null
fi

# Named volumes, not the instance directory: kubelet and containerd need real
# filesystem semantics, and local-path PVCs live under /var/lib/rancher/k3s.
for vol in rancher kubelet log; do
    docker volume create "${CONTAINER}-${vol}" >/dev/null
done

args=(
    run --rm --init
    --name "$CONTAINER"
    --hostname "$K3S_NODE_NAME"
    --privileged
    --net host
    --env-file "$SECRETS_FILE"
    --tmpfs /run
    --tmpfs /var/run
    -v /lib/modules:/lib/modules:ro
    -v "${CONTAINER}-rancher:/var/lib/rancher/k3s"
    -v "${CONTAINER}-kubelet:/var/lib/kubelet"
    -v "${CONTAINER}-log:/var/log"
)

# CI runners mount a docker socket by hostPath and launch job containers as
# siblings. Without this passthrough that hostPath resolves inside the node
# container, where no daemon is listening.
#
# Consequence: job containers run on the AMP HOST's daemon, outside this
# container's cgroup, so the caps below do NOT bound them. Throttle builds with
# `container.options` in the act_runner config instead - see k3snodeREADME.md.
if [[ "${DOCKER_SOCKET_PASSTHROUGH:-true}" == "true" ]]; then
    [[ -S /var/run/docker.sock ]] || die "DOCKER_SOCKET_PASSTHROUGH is on but /var/run/docker.sock does not exist"
    args+=(-v /var/run/docker.sock:/var/run/docker.sock)
fi

# These bound the kubelet, containerd and any pod that does NOT escape via the
# docker socket. See the note above for what they do not bound.
[[ -n "${NODE_CPUS:-}"       && "$NODE_CPUS" != "0"       ]] && args+=(--cpus "$NODE_CPUS")
[[ -n "${NODE_MEMORY:-}"     && "$NODE_MEMORY" != "0"     ]] && args+=(--memory "$NODE_MEMORY" --memory-swap "$NODE_MEMORY")
[[ -n "${NODE_PIDS_LIMIT:-}" && "$NODE_PIDS_LIMIT" != "0" ]] && args+=(--pids-limit "$NODE_PIDS_LIMIT")

args+=("$NODE_IMAGE" agent)
args+=(--server "$K3S_URL" --node-name "$K3S_NODE_NAME")

if [[ -n "${K3S_NODE_LABELS:-}" ]]; then
    IFS=',' read -ra labels <<< "$K3S_NODE_LABELS"
    for l in "${labels[@]}"; do [[ -n "$l" ]] && args+=(--node-label "$l"); done
fi

# Defaults to a NoSchedule taint: nothing lands here unless it explicitly
# tolerates it, because the control plane cannot reach this node's kubelet.
if [[ -n "${K3S_NODE_TAINTS:-}" ]]; then
    IFS=',' read -ra taints <<< "$K3S_NODE_TAINTS"
    for t in "${taints[@]}"; do [[ -n "$t" ]] && args+=(--node-taint "$t"); done
fi

if [[ -n "${K3S_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    extra=($K3S_EXTRA_ARGS)
    args+=("${extra[@]}")
fi

cleanup() {
    trap - TERM INT EXIT
    log "stopping $CONTAINER (${STOP_TIMEOUT}s grace)"
    docker stop -t "$STOP_TIMEOUT" "$CONTAINER" >/dev/null 2>&1 || true
    log "node stopped"
}
trap cleanup TERM INT EXIT

log "image:  $NODE_IMAGE"
log "node:   $K3S_NODE_NAME -> $K3S_URL"
log "limits: cpus=${NODE_CPUS:-unset} memory=${NODE_MEMORY:-unset} pids=${NODE_PIDS_LIMIT:-unset} (kubelet/containerd only)"

docker "${args[@]}" &
docker_pid=$!
wait "$docker_pid"
rc=$?
log "container exited with status $rc"
exit "$rc"
