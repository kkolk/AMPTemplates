#!/usr/bin/env bash
# Installs everything the CI runner needs into the AMP instance directory.
# Runs as the unprivileged AMP user - nothing here touches the host.
#
# Invoked by the template's update stages with the instance root as $1.

set -euo pipefail

ROOT="${1:?usage: install.sh <instance-root>}"
cd "$ROOT"

ACT_RUNNER_VERSION="${ACT_RUNNER_VERSION:-0.2.13}"
TAILSCALE_VERSION="${TAILSCALE_VERSION:-1.86.2}"
RUST_TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
NODE_VERSION="${NODE_VERSION:-22.11.0}"

# The default locations, deliberately: workflows cache ~/.cargo/registry, and
# pointing CARGO_HOME into the instance directory would make that cache a
# silent no-op. Overridable if a future instance needs isolation.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cargo}"

case "$(uname -m)" in
    x86_64)        GOARCH=amd64; NODEARCH=x64 ;;
    aarch64|arm64) GOARCH=arm64; NODEARCH=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

mkdir -p bin state cache git-mirror workspace toolcache "$CARGO_HOME/bin"

fetch() { curl -fL --retry 3 --progress-bar -o "$1" "$2"; }

# --- act_runner --------------------------------------------------------------
if [[ ! -x bin/act_runner ]] || ! bin/act_runner --version 2>/dev/null | grep -q "$ACT_RUNNER_VERSION"; then
    echo ">> act_runner $ACT_RUNNER_VERSION"
    fetch bin/act_runner \
        "https://gitea.com/gitea/act_runner/releases/download/v${ACT_RUNNER_VERSION}/act_runner-${ACT_RUNNER_VERSION}-linux-${GOARCH}"
    chmod +x bin/act_runner
fi

# --- tailscale (static, userspace mode - no root, no /dev/net/tun) -----------
if [[ ! -x bin/tailscaled ]] || ! bin/tailscaled --version 2>/dev/null | grep -q "$TAILSCALE_VERSION"; then
    echo ">> tailscale $TAILSCALE_VERSION"
    fetch /tmp/ts.tgz "https://pkgs.tailscale.com/stable/tailscale_${TAILSCALE_VERSION}_${GOARCH}.tgz"
    tar xzf /tmp/ts.tgz -C /tmp
    mv "/tmp/tailscale_${TAILSCALE_VERSION}_${GOARCH}/tailscale"  bin/tailscale
    mv "/tmp/tailscale_${TAILSCALE_VERSION}_${GOARCH}/tailscaled" bin/tailscaled
    chmod +x bin/tailscale bin/tailscaled
    rm -rf /tmp/ts.tgz "/tmp/tailscale_${TAILSCALE_VERSION}_${GOARCH}"
fi

# --- Rust --------------------------------------------------------------------
# Host-executor jobs need the toolchain in the instance dir, since there is no
# rust-ci container to provide it. rustup installs entirely under $HOME-style
# paths, which we point inside the instance.
if [[ ! -x "$CARGO_HOME/bin/cargo" ]]; then
    echo ">> rust $RUST_TOOLCHAIN"
    fetch /tmp/rustup-init.sh https://sh.rustup.rs
    sh /tmp/rustup-init.sh -y --no-modify-path --profile minimal \
        --default-toolchain "$RUST_TOOLCHAIN" --component rustfmt --component clippy
    rm -f /tmp/rustup-init.sh
else
    echo ">> rust: updating $RUST_TOOLCHAIN"
    "$CARGO_HOME/bin/rustup" update "$RUST_TOOLCHAIN"
fi

# Tools the rust-ci jobs invoke directly. cargo-binstall fetches prebuilt
# binaries so this stage does not turn into a from-source compile.
if [[ ! -x "$CARGO_HOME/bin/cargo-binstall" ]]; then
    echo ">> cargo-binstall"
    fetch /tmp/binstall.tgz \
        "https://github.com/cargo-bins/cargo-binstall/releases/latest/download/cargo-binstall-$(uname -m)-unknown-linux-musl.tgz"
    tar xzf /tmp/binstall.tgz -C "$CARGO_HOME/bin"
    rm -f /tmp/binstall.tgz
fi
for tool in cargo-hakari sccache cargo-nextest; do
    if [[ ! -x "$CARGO_HOME/bin/${tool}" ]]; then
        echo ">> $tool"
        "$CARGO_HOME/bin/cargo-binstall" --no-confirm --no-symlinks "$tool" || \
            echo "WARNING: could not install $tool - jobs needing it will fail" >&2
    fi
done

# --- Node --------------------------------------------------------------------
# actions/setup-node can fetch its own, but seeding one avoids a download on
# every cold job and gives workflows a node on PATH without the action.
if [[ ! -x "node/bin/node" ]] || ! node/bin/node --version 2>/dev/null | grep -q "v${NODE_VERSION}"; then
    echo ">> node $NODE_VERSION"
    fetch /tmp/node.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${NODEARCH}.tar.xz"
    rm -rf node && mkdir -p node
    tar xJf /tmp/node.tar.xz -C node --strip-components=1
    rm -f /tmp/node.tar.xz
fi

echo
echo "Installed into $ROOT:"
printf '  act_runner %s\n' "$(bin/act_runner --version 2>/dev/null | head -1)"
printf '  tailscale  %s\n' "$(bin/tailscaled --version 2>/dev/null | head -1)"
printf '  cargo      %s\n' "$("$CARGO_HOME/bin/cargo" --version 2>/dev/null)"
printf '  node       %s\n' "$(node/bin/node --version 2>/dev/null)"
