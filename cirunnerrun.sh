#!/usr/bin/env bash
# CI Runner (Tailscale) - AMP launcher. Runs entirely as the unprivileged AMP
# user: no root, no sudo, no container runtime, nothing outside the instance
# directory.
#
# tailscaled runs in userspace-networking mode, which needs neither /dev/net/tun
# nor NET_ADMIN. It exposes a SOCKS5 and an HTTP proxy on localhost; everything
# that must reach git.frostbyte.us is pointed at those.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

log() { printf '[ci-runner] %s\n' "$*"; }
die() { printf '[ci-runner] FATAL: %s\n' "$*" >&2; exit 1; }

SOCKS_PORT="${SOCKS_PORT:-1055}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-1056}"

[[ -x bin/act_runner ]] || die "bin/act_runner missing - run Update on this instance first"
[[ -x bin/tailscaled ]] || die "bin/tailscaled missing - run Update on this instance first"
[[ -n "${TS_AUTHKEY:-}" ]] || die "Tailscale Auth Key is not set in the instance settings"
[[ -n "${GITEA_INSTANCE_URL:-}" ]] || die "Gitea Instance URL is not set"

# --- tailscale ---------------------------------------------------------------
log "starting tailscaled (userspace networking)"
./bin/tailscaled \
    --tun=userspace-networking \
    --state="$ROOT/state/tailscaled.state" \
    --socket="$ROOT/state/tailscaled.sock" \
    --socks5-server="localhost:${SOCKS_PORT}" \
    --outbound-http-proxy-listen="localhost:${HTTP_PROXY_PORT}" &
tailscaled_pid=$!

for _ in $(seq 30); do
    [[ -S "$ROOT/state/tailscaled.sock" ]] && break
    kill -0 "$tailscaled_pid" 2>/dev/null || die "tailscaled died during startup"
    sleep 1
done
[[ -S "$ROOT/state/tailscaled.sock" ]] || die "tailscaled socket never appeared"

TS="./bin/tailscale --socket=$ROOT/state/tailscaled.sock"
up_args=(--authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-amp-ci-runner}")
# Pulls in the routes the in-cluster subnet router advertises.
[[ "${TS_ACCEPT_ROUTES:-true}" == "true" ]] && up_args+=(--accept-routes)

log "bringing up tailscale"
$TS up "${up_args[@]}" || die "tailscale up failed"
log "tailnet address: $($TS ip -4 2>/dev/null | head -1)"

# socks5h, not socks5: the 'h' makes the proxy resolve hostnames. Without it
# git.frostbyte.us is resolved locally, where it does not exist, and every
# fetch fails with a DNS error that looks nothing like a proxy problem.
export ALL_PROXY="socks5h://127.0.0.1:${SOCKS_PORT}"
# Node-based actions and act_runner's own Gitea API calls speak HTTP CONNECT,
# not SOCKS, so they get the other listener.
export HTTP_PROXY="http://127.0.0.1:${HTTP_PROXY_PORT}"
export HTTPS_PROXY="$HTTP_PROXY"
export http_proxy="$HTTP_PROXY" https_proxy="$HTTP_PROXY"
# The runner's own cache server is local; proxying it would deadlock.
export NO_PROXY="localhost,127.0.0.1,::1"
export no_proxy="$NO_PROXY"

# --- toolchain on PATH for host-executor jobs --------------------------------
export RUSTUP_HOME="$ROOT/rust/rustup"
export CARGO_HOME="$ROOT/rust/cargo"
export PATH="$ROOT/rust/cargo/bin:$ROOT/node/bin:$ROOT/bin:$PATH"
# Workflows read this instead of a hardcoded /ci-cache, which cannot be created
# without root. See cirunnerREADME.md for the one-line workflow change.
export CI_CACHE_DIR="$ROOT/cache/ci"
mkdir -p "$CI_CACHE_DIR"
[[ -x "$ROOT/rust/cargo/bin/sccache" ]] && export RUSTC_WRAPPER="$ROOT/rust/cargo/bin/sccache"

# --- runner config -----------------------------------------------------------
cat > state/config.yaml <<YAML
log:
  level: info
runner:
  file: $ROOT/state/.runner
  capacity: ${RUNNER_CAPACITY:-2}
  timeout: ${RUNNER_TIMEOUT:-3h}
  action_shallow_clone: true
  envs:
    CI_CACHE_DIR: "$CI_CACHE_DIR"
    ALL_PROXY: "$ALL_PROXY"
    HTTP_PROXY: "$HTTP_PROXY"
    HTTPS_PROXY: "$HTTPS_PROXY"
    NO_PROXY: "$NO_PROXY"
    CARGO_HOME: "$CARGO_HOME"
    RUSTUP_HOME: "$RUSTUP_HOME"
cache:
  enabled: true
  dir: $ROOT/cache/actions
  host: "127.0.0.1"
  port: ${CACHE_PORT:-8088}
  offline_mode: true
  retention: ${CACHE_RETENTION:-168h}
  size_limit: ${CACHE_SIZE_LIMIT:-30GB}
host:
  workdir_parent: $ROOT/workspace
container:
  # No container runtime here. Every advertised label maps to :host, so this
  # section is inert - it is present only so act_runner does not warn.
  force_pull: false
YAML


# --- connectivity diagnostics ------------------------------------------------
# There is no shell on this host, so the console is the only instrument. Run
# these before registering: each line isolates one hop, so the first failure
# tells you which one is broken.
diagnose() {
    local host="${GITEA_INSTANCE_URL#*://}"; host="${host%%/*}"
    echo "--------------------------------------------------------------"
    echo "[diag] tailnet peers and advertised routes:"
    $TS status 2>&1 | sed 's/^/[diag]   /' | head -20
    echo "[diag] accepted subnet routes:"
    $TS debug prefs 2>/dev/null | grep -iE 'routeall|exitnode' | sed 's/^/[diag]   /' || \
        echo "[diag]   (could not read prefs)"
    echo "[diag] resolving $host through tailscaled:"
    $TS dns query "$host" A 2>&1 | sed 's/^/[diag]   /' | head -10
    echo "[diag] reaching CoreDNS (10.43.0.10) over the tailnet:"
    $TS ping --timeout=5s --c=1 10.43.0.10 2>&1 | sed 's/^/[diag]   /' | head -5
    echo "[diag] HTTPS to $host via the HTTP proxy:"
    curl -sS --max-time 20 -o /dev/null -w '[diag]   HTTP %{http_code} in %{time_total}s\n' \
        --proxy "$HTTP_PROXY" "${GITEA_INSTANCE_URL}/api/v1/version" 2>&1 | sed 's/^curl/[diag]   curl/'
    echo "[diag] HTTPS to $host via the SOCKS proxy:"
    curl -sS --max-time 20 -o /dev/null -w '[diag]   HTTP %{http_code} in %{time_total}s\n' \
        --proxy "$ALL_PROXY" "${GITEA_INSTANCE_URL}/api/v1/version" 2>&1 | sed 's/^curl/[diag]   curl/'
    echo "--------------------------------------------------------------"
}

if [[ "${RUN_DIAGNOSTICS:-true}" == "true" ]]; then
    diagnose
fi

# --- register (first run only) ----------------------------------------------
if [[ ! -f state/.runner ]]; then
    [[ -n "${GITEA_RUNNER_REGISTRATION_TOKEN:-}" ]] || \
        die "no registration token set, and this runner has not registered yet"
    log "registering as ${GITEA_RUNNER_NAME:-amp-ci-runner}"
    ./bin/act_runner --config state/config.yaml register --no-interactive \
        --instance "$GITEA_INSTANCE_URL" \
        --token "$GITEA_RUNNER_REGISTRATION_TOKEN" \
        --name "${GITEA_RUNNER_NAME:-amp-ci-runner}" \
        --labels "${GITEA_RUNNER_LABELS:-self-hosted:host,linux:host,build:host,rust-ci:host}" \
        || { diagnose; die "registration failed. If the diag lines above show HTTP 000 the runner cannot reach Gitea at all (routing or ACL); a real HTTP code means it reached Gitea and the token is the problem."; }
    log "registered"
fi

cleanup() {
    trap - TERM INT EXIT
    log "shutting down"
    [[ -n "${runner_pid:-}" ]] && kill -TERM "$runner_pid" 2>/dev/null
    [[ -n "${runner_pid:-}" ]] && wait "$runner_pid" 2>/dev/null
    kill -TERM "$tailscaled_pid" 2>/dev/null
    log "stopped"
}
trap cleanup TERM INT EXIT

log "starting act_runner daemon"
./bin/act_runner --config state/config.yaml daemon &
runner_pid=$!
wait "$runner_pid"
rc=$?
log "act_runner exited with status $rc"
exit "$rc"
