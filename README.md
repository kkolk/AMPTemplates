# kkolk AMP Templates

Personal [AMP](https://cubecoders.com/AMP) Generic Module templates. Forked from
[CubeCoders/AMPTemplates](https://github.com/CubeCoders/AMPTemplates); the
upstream templates have been removed, since AMP ships that repository as a
template source already. Only the templates below live here.

Add as a template source in AMP under **Configuration → Instance Deployment →
Template Repositories**:

```
https://github.com/kkolk/AMPTemplates
```

## Templates

| Template | What it is |
|---|---|
| **CI Runner (Tailscale)** — `cirunner*` | Self-contained Gitea Actions runner. Runs entirely as the unprivileged AMP user — no root, no container runtime — and reaches a tailnet-only Gitea through userspace Tailscale. [Setup](cirunnerREADME.md) |
| **k3s Node (CI)** — `k3snode*` | Joins the host to a remote k3s cluster as a tainted agent node in a privileged container. Needs root on the host; kept for hosts where that is available. [Setup](k3snodeREADME.md) |
| **Extraction** — `extraction*` | Dedicated server for [Extraction](https://github.com/aleccarper/extraction). |

`CI Runner` and `k3s Node` are two answers to the same problem — putting CI on a
remote AMP host. Which one applies depends entirely on whether you have root
there. `CI Runner` does not need it.

## Note on the file layout

AMP discovers templates by their `.kvp` file and resolves the sibling
`*config.json`, `*ports.json`, `*updates.json` and `*metaconfig.json` by name
prefix, so everything sits flat at the repository root. `manifest.json` carries
the repository-level metadata AMP reads when adding the source.

**Do not rename this repository.** The `CI Runner` and `k3s Node` update stages
fetch their launcher scripts from `raw.githubusercontent.com` on this path;
renaming breaks the next Update on any live instance.
