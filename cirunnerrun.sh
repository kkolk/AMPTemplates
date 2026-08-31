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

LAUNCHER_REV="2026-08-31-capacity"
SOCKS_PORT="${SOCKS_PORT:-1055}"
HTTP_PROXY_PORT="${HTTP_PROXY_PORT:-1056}"

[[ -x bin/act_runner ]] || die "bin/act_runner missing - run Update on this instance first"
[[ -x bin/tailscaled ]] || die "bin/tailscaled missing - run Update on this instance first"
[[ -n "${TS_AUTHKEY:-}" ]] || die "Tailscale Auth Key is not set in the instance settings"
[[ -n "${GITEA_INSTANCE_URL:-}" ]] || die "Gitea Instance URL is not set"


# Bash defers trap handlers until the current foreground command returns, so a
# long-running call in the foreground makes this script deaf to SIGTERM. Run
# them backgrounded and wait, which lets the trap fire immediately.
child_pid=""
run_interruptible() {
    "$@" &
    local pid=$!
    child_pid=$pid
    wait "$pid"
    local rc=$?
    child_pid=""
    return $rc
}

# --- /etc/hosts override (no root) -------------------------------------------
# tailscaled in userspace mode cannot become the system resolver without root,
# and proxied connections are resolved BY TAILSCALED, not by the client. So the
# override has to cover tailscaled, which means re-execing the whole script
# inside an unprivileged user+mount namespace before tailscaled starts.
#
# tailscale up is given --accept-dns=false below: inside the namespace
# tailscaled believes it is root and would otherwise try to manage
# /etc/resolv.conf, which it cannot actually write.
HOSTS_FILE="$ROOT/state/hosts.extra.generated"

if [[ "${HOSTS_NS_ACTIVE:-0}" != "1" ]]; then
    if [[ -z "${EXTRA_HOSTS:-}" && -r "$ROOT/state/hosts.extra" ]]; then
        EXTRA_HOSTS="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/state/hosts.extra" | paste -sd ';' -)"
    fi
    if [[ -n "${EXTRA_HOSTS:-}" ]]; then
        if unshare --user --map-root-user --mount true 2>/dev/null; then
            { cat /etc/hosts; echo; printf '%s\n' "${EXTRA_HOSTS//;/$'\n'}"; } > "$HOSTS_FILE"
            log "applying host entries in a private mount namespace:"
            printf '%s\n' "${EXTRA_HOSTS//;/$'\n'}" | sed 's/^/[ci-runner]   /'
            export HOSTS_NS_ACTIVE=1 EXTRA_HOSTS
            exec unshare --user --map-root-user --mount bash -c '
                mount --bind "$1" /etc/hosts || { echo "[ci-runner] FATAL: bind mount failed" >&2; exit 71; }
                shift
                exec "$@"
            ' _ "$HOSTS_FILE" "$0" "$@"
        else
            log "WARNING: unprivileged user namespaces are unavailable; host"
            log "WARNING: entries cannot be applied and a tailnet-only hostname"
            log "WARNING: will not resolve."
        fi
    else
        log "no extra host entries configured (create state/hosts.extra with"
        log "lines like '192.168.2.117 git.frostbyte.us')"
    fi
fi
HOSTS_NS_OK="${HOSTS_NS_ACTIVE:-0}"

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
# --accept-dns=false: inside the mount namespace tailscaled believes it is
# root and would try to manage /etc/resolv.conf, which it cannot write. We
# resolve through /etc/hosts instead, so its DNS handling is unwanted.
up_args=(--accept-dns=false --authkey="$TS_AUTHKEY" --hostname="${TS_HOSTNAME:-amp-ci-runner}")
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
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"
export PATH="$CARGO_HOME/bin:$ROOT/node/bin:$ROOT/bin:$PATH"
# Workflows read this instead of a hardcoded /ci-cache, which cannot be created
# without root. See cirunnerREADME.md for the one-line workflow change.
export CI_CACHE_DIR="$ROOT/cache/ci"
mkdir -p "$CI_CACHE_DIR"
[[ -x "$CARGO_HOME/bin/sccache" ]] && export RUSTC_WRAPPER="$CARGO_HOME/bin/sccache"

# The C toolchain lives in the instance, not on the host. It goes first on PATH
# so gcc, cc and mold resolve for repos that name them explicitly.
if [[ -x "$ROOT/toolchain/bin/gcc" ]]; then
    export PATH="$ROOT/toolchain/bin:$PATH"
fi

# --- runner config -----------------------------------------------------------
cat > state/config.yaml <<YAML
log:
  level: info
runner:
  file: $ROOT/state/.runner
  # Host-executor jobs get NO cgroup: container.options, which throttles jobs
  # on the homelab runners, applies only to the container executor. The real
  # ceiling here is CARGO_BUILD_JOBS in each workflow (4-6) times this number,
  # against a shared 44-thread box. More slots also keep this runner eligible
  # for work longer, since a runner at capacity stops competing.
  #
  # Beware same-repo concurrency: jobs sharing a persistent CARGO_TARGET_DIR
  # serialise on cargo's file lock, so those slots sit blocked rather than
  # doing work. Extra capacity mostly buys parallelism ACROSS repos.
  capacity: ${RUNNER_CAPACITY:-4}
  timeout: ${RUNNER_TIMEOUT:-3h}
  # Gitea has no runner priority (go-gitea/gitea#27042). Runners poll for work
  # and the first to poll wins, so a short interval biases jobs here without
  # ever blocking: if this host is busy or down, the others pick up normally.
  # fetch_interval_max matters as much as fetch_interval - an idle runner backs
  # off exponentially, and a backed-off runner loses the race.
  fetch_interval: ${FETCH_INTERVAL:-1s}
  fetch_interval_max: ${FETCH_INTERVAL_MAX:-2s}
  action_shallow_clone: true
  envs:
    CI_CACHE_DIR: "$CI_CACHE_DIR"
    ALL_PROXY: "$ALL_PROXY"
    HTTP_PROXY: "$HTTP_PROXY"
    HTTPS_PROXY: "$HTTPS_PROXY"
    NO_PROXY: "$NO_PROXY"
    CARGO_HOME: "$CARGO_HOME"
    RUSTUP_HOME: "$RUSTUP_HOME"
    PATH: "$PATH"
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
    echo "[diag] hosts override:"
    echo "[diag]   launcher revision: ${LAUNCHER_REV:-unknown}"
    echo "[diag]   looking for: $ROOT/state/hosts.extra"
    if [[ -r "$ROOT/state/hosts.extra" ]]; then
        echo "[diag]   found, contents:"
        sed 's/^/[diag]     /' "$ROOT/state/hosts.extra"
    else
        echo "[diag]   NOT FOUND or unreadable - this is why the override is off"
        ls -la "$ROOT/state/" 2>&1 | sed 's/^/[diag]     /' | head -12
    fi
    if unshare --user --map-root-user --mount true 2>/dev/null; then
        echo "[diag]   unprivileged user namespaces: available"
    else
        echo "[diag]   unprivileged user namespaces: BLOCKED by kernel"
    fi
    echo "[diag]   EXTRA_HOSTS=[${EXTRA_HOSTS:-}]"
    echo "[diag]   override active: ${HOSTS_NS_OK/1/yes}"
    if [[ "$HOSTS_NS_OK" == "1" ]]; then
        getent hosts "$host" 2>&1 | sed 's/^/[diag]   /' || \
            echo "[diag]   $host not present in the override"
    fi
    echo "[diag] HTTPS to $host via the HTTP proxy:"
    curl -sS --max-time 20 -o /dev/null -w '[diag]   HTTP %{http_code} in %{time_total}s\n' \
        --proxy "$HTTP_PROXY" "${GITEA_INSTANCE_URL}/api/v1/version" 2>&1 | sed 's/^curl/[diag]   curl/'
    echo "[diag] HTTPS to $host via the SOCKS proxy:"
    curl -sS --max-time 20 -o /dev/null -w '[diag]   HTTP %{http_code} in %{time_total}s\n' \
        --proxy "$ALL_PROXY" "${GITEA_INSTANCE_URL}/api/v1/version" 2>&1 | sed 's/^curl/[diag]   curl/'
    echo "--------------------------------------------------------------"
}

if [[ "${RUN_DIAGNOSTICS:-true}" == "true" ]]; then
    run_interruptible diagnose || echo "[diag] diagnostics did not complete"
fi

# Labels: template settings cannot reach a running instance without an AMP
# template refresh, so state/labels overrides them the same way hosts.extra
# does. Changing labels requires re-registration - delete state/.runner.
if [[ -z "${GITEA_RUNNER_LABELS:-}" && -r "$ROOT/state/labels" ]]; then
    GITEA_RUNNER_LABELS="$(grep -vE '^[[:space:]]*(#|$)' "$ROOT/state/labels" | paste -sd ',' -)"
    log "labels loaded from state/labels"
fi
# amp:host distinguishes this runner from the homelab ones, which advertise the
# same general-purpose labels - without it a job cannot be aimed here.
GITEA_RUNNER_LABELS="${GITEA_RUNNER_LABELS:-self-hosted:host,linux:host,build:host,rust-ci:host,amp:host}"
log "labels: $GITEA_RUNNER_LABELS"

# --- register (first run only) ----------------------------------------------
if [[ ! -f state/.runner ]]; then
    [[ -n "${GITEA_RUNNER_REGISTRATION_TOKEN:-}" ]] || \
        die "no registration token set, and this runner has not registered yet"
    log "registering as ${GITEA_RUNNER_NAME:-amp-ci-runner}"
    # act_runner retries the instance ping indefinitely; without a bound a bad
    # route leaves the instance unstoppable rather than failing visibly.
    run_interruptible timeout "${REGISTER_TIMEOUT:-120}" \
        ./bin/act_runner --config state/config.yaml register --no-interactive \
        --instance "$GITEA_INSTANCE_URL" \
        --token "$GITEA_RUNNER_REGISTRATION_TOKEN" \
        --name "${GITEA_RUNNER_NAME:-amp-ci-runner}" \
        --labels "$GITEA_RUNNER_LABELS" \
        || { diagnose; die "registration failed. If the diag lines above show HTTP 000 the runner cannot reach Gitea at all (routing or ACL); a real HTTP code means it reached Gitea and the token is the problem."; }
    log "registered"
fi

cleanup() {
    trap - TERM INT EXIT
    log "shutting down"
    for pid in "${child_pid:-}" "${runner_pid:-}"; do
        [[ -n "$pid" ]] && kill -TERM "$pid" 2>/dev/null
    done
    for pid in "${child_pid:-}" "${runner_pid:-}"; do
        [[ -n "$pid" ]] && { wait "$pid" 2>/dev/null || true; }
    done
    if [[ -n "${tailscaled_pid:-}" ]]; then
        kill -TERM "$tailscaled_pid" 2>/dev/null
        for _ in $(seq 10); do
            kill -0 "$tailscaled_pid" 2>/dev/null || break
            sleep 1
        done
        kill -KILL "$tailscaled_pid" 2>/dev/null
    fi
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
