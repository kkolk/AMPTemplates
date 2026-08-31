# Test Runner — AMP Generic module template

A self-contained Gitea Actions runner that installs and runs entirely as the
unprivileged AMP user. **No root, no sudo, no container runtime, nothing written
outside the instance directory.**

Built for a shared datacenter host where you have an AMP panel and nothing else.

## How it reaches Gitea

`git.frostbyte.us` is tailnet-only, so Tailscale is required. The instance runs
`tailscaled --tun=userspace-networking`, which needs neither `/dev/net/tun` nor
`NET_ADMIN` — that is what makes the whole thing rootless.

Userspace mode gives no network interface, only proxies, so the launcher exports
`ALL_PROXY` (SOCKS5) and `HTTP(S)_PROXY` (HTTP CONNECT) on localhost, with
`NO_PROXY` covering the local cache server.

### Name resolution — the part that is not obvious

Rootless userspace mode cannot resolve a tailnet-only hostname, and no amount of
Tailscale DNS configuration fixes it:

- tailscaled cannot write `/etc/resolv.conf` without root, so it never becomes
  the system resolver (`dns: using dns.noopManager`).
- Its internal resolver *does* hold the split-DNS routes, but nothing consults
  it — `tailscale dns query` returns SERVFAIL and the proxies use the host
  resolver at `127.0.0.53`.
- **Proxied connections are resolved by tailscaled, not by the client.**
  `act_runner` sends `CONNECT git.frostbyte.us:443` and tailscaled does the
  lookup, so overriding resolution for `act_runner` alone changes nothing.

The fix is a static hosts entry applied to the **whole process tree**. The
launcher re-execs itself inside an unprivileged user + mount namespace and
bind-mounts a generated hosts file over `/etc/hosts`, before tailscaled starts.
Nothing on the host is modified, and no privileges are required beyond the
kernel permitting unprivileged user namespaces.

`tailscale up` passes `--accept-dns=false`: inside the namespace tailscaled
believes it is root and would otherwise try to manage `/etc/resolv.conf`, which
it cannot write. Its DNS handling is unwanted once `/etc/hosts` answers.

Expect `dns-forward-failing` warnings in the log — tailscaled complaining it
cannot reach the tailnet's configured DNS servers. Cosmetic; resolution does not
go through them.

### Setting the host entries

Either the **Extra Host Entries** setting, or `state/hosts.extra` in the
instance directory, one `IP hostname` pair per line. The file is the escape
hatch: new template settings only reach an instance when AMP re-reads the
template repository, whereas the file works immediately via the File Manager.

```
192.168.2.117 git.frostbyte.us
```

This pins an IP. If Traefik moves off `192.168.2.117`, jobs fail with connection
errors rather than DNS errors.

## Updating the launcher

`raw.githubusercontent.com` caches branch paths for several minutes and ignores
both cache-busting query strings and `Cache-Control: no-cache`, so fetching
`.../main/...` can install a stale script. The update stage resolves the current
commit SHA through the GitHub API and fetches the immutable per-commit URL
instead, and prints `LAUNCHER_REV` so the installed revision is visible.

`run.sh` also logs its revision into the diagnostics block. **Check it first**
when a fix appears not to have taken — a stale launcher makes everything below
it meaningless. Uploading `cirunnerrun.sh` directly through the File Manager
bypasses the CDN entirely.

## What it can and cannot run

Everything advertised maps to the `:host` executor. Label→executor mapping is
**per-runner**, so this runner takes `rust-ci:host` while `runner-1` keeps
`rust-ci:docker://…` — the same `runs-on: [rust-ci]` jobs, no workflow changes.

**Runs here:** `toolkit`'s rust-ci jobs, `rata`'s `lint` (fmt, hakari, seam
scripts), and any compile/test/lint work. The instance ships rustup with
rustfmt and clippy, `cargo-hakari`, `sccache`, `cargo-nextest`, and Node.

**Cannot run here, keep on the homelab runners:** anything invoking the Docker
CLI (`nanobot`, `rata`'s `docker buildx build --load` image job) and any job with
a top-level `container:` key. There is no container runtime. Do not advertise
the `docker` label — a job that lands here and shells out to `docker` fails
partway through, which is worse than never being scheduled.

### One workflow change you need to make

`rata`'s `check` job hardcodes `CARGO_TARGET_DIR: /ci-cache/rata/target`.
Creating `/ci-cache` needs root. The launcher exports `CI_CACHE_DIR` pointing
inside the instance, so change that line to:

```yaml
CARGO_TARGET_DIR: ${CI_CACHE_DIR:-/ci-cache}/rata/target
```

That keeps the homelab runners working unchanged — they have `/ci-cache` and no
`CI_CACHE_DIR` — while letting this one use its own directory. The job's
existing prune step needs the same treatment.

## Caching

All of it lives in the instance directory and survives restarts, with no PVC and
no host paths:

| Path | Holds |
|---|---|
| `cache/actions` | the built-in `actions/cache` server (30GB cap, 7-day retention) |
| `cache/ci` | `CI_CACHE_DIR` — cargo target dirs |
| `rust/cargo` | the cargo registry, shared across jobs |
| `git-mirror` | reserved for a mirror-backed checkout |
| `workspace` | host-executor job workdirs |

Since jobs run on the host executor, `actions/cache` reaches the cache server on
`127.0.0.1` — none of the docker-bridge addressing problems the k3s design had.

## Setup

No host prerequisites. Add this repo to AMP's template sources, create a
**Test Runner** instance, then fill in:

- **Gitea Instance URL** — `https://git.frostbyte.us`
- **Runner Registration Token** — from Gitea's Actions settings
- **Tailscale Auth Key** — reusable and pre-approved

Run **Update** (downloads act_runner, Tailscale, rustup, Node — a few minutes on
first run), then Start. The runner registers itself on first start and appears
in Gitea's runner list.

Both secrets are stored in AMP's configuration database. Without root there is
nowhere better to put them; anyone with AMP admin on this instance can read them.

## Files

| File | Role |
|---|---|
| `cirunner.kvp` | template root |
| `cirunnerconfig.json` | the settings UI |
| `cirunnerports.json` | the local cache-server port |
| `cirunnerupdates.json` | update stages |
| `cirunnermetaconfig.json` | unused — settings arrive as env vars |
| `cirunnerrun.sh` | launcher: tailscaled, proxies, config, register, daemon |
| `cirunnerinstall.sh` | unprivileged installer for every binary and toolchain |

The `k3snode*` files are the earlier design for the same host and still work if
you ever get root there. This template needs none of it.

## Not yet verified

Nothing here has been run. Most likely to need attention:

- **Whether Tailscale's userspace proxies pass non-tailnet traffic through.**
  Jobs also fetch from crates.io, npm and nodejs.org. If those break with the
  proxy set, the fix is a `NO_PROXY` listing the public hosts.
- **`actions/checkout` under a SOCKS proxy.** It shells out to `git` and also
  makes its own HTTP calls; the two honour different proxy variables, which is
  why both are exported. Registration working does not prove checkout works.
- Whether `cargo-binstall` has prebuilt binaries for all three tools on this
  architecture; the installer warns rather than failing if one is missing.
- Whether act_runner's host executor finds the toolchain on `PATH` for every
  step type, `actions/setup-node` in particular.
