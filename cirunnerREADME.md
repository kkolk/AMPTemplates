# CI Runner (Tailscale) — AMP Generic module template

A self-contained Gitea Actions runner that installs and runs entirely as the
unprivileged AMP user. **No root, no sudo, no container runtime, nothing written
outside the instance directory.**

Built for a shared datacenter host where you have an AMP panel and nothing else.

## How it reaches Gitea

`git.frostbyte.us` is tailnet-only, so Tailscale is required, not optional. The
instance runs `tailscaled --tun=userspace-networking`, which needs neither
`/dev/net/tun` nor `NET_ADMIN` — that is what makes the whole thing rootless.

Userspace mode gives no network interface, only proxies, so the launcher exports:

| Variable | Value | Used by |
|---|---|---|
| `ALL_PROXY` | `socks5h://127.0.0.1:1055` | `git` |
| `HTTP(S)_PROXY` | `http://127.0.0.1:1056` | act_runner, node-based actions |
| `NO_PROXY` | `localhost,127.0.0.1,::1` | the local cache server |

**The `h` in `socks5h` is load-bearing.** It makes the proxy resolve hostnames.
Without it `git.frostbyte.us` is resolved locally, where it does not exist, and
every fetch fails with a DNS error that looks nothing like a proxy problem.

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
**CI Runner (Tailscale)** instance, then fill in:

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
  why both are exported.
- Whether `cargo-binstall` has prebuilt binaries for all three tools on this
  architecture; the installer warns rather than failing if one is missing.
- Whether act_runner's host executor finds the toolchain on `PATH` for every
  step type, `actions/setup-node` in particular.
