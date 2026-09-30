# Hamra Control

Control center for the Hamra (NixOS) config, inside Noctalia. It lists the
`hamra.programs.*` toggles with their real eval state, groups SSH and GPG key
tasks in one place, installs and removes Flatpaks and web apps, runs flake
updates and rebuilds, and exposes common system chores — replacing the old
terminal `hamra-menu`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `gabrielnathan929/hamra-control` |
| Entries | panel: `main`; launcher provider: `menu` |
| Launcher Prefix | `/hamra` |

Open the panel with:

```sh
noctalia msg panel-toggle gabrielnathan929/hamra-control:main
```

## Requirements

- A Hamra host checkout at `/etc/nixos` (or set `HAMRA_REPO` to the repo path).
- `nix` on `PATH` for reading the toggles via `nix eval`.
- `flatpak` for the Instalar/Remover views.
- Write access to `hosts/<host>/configuration.nix` for the toggle switches (when
  the repo lives in `/etc/nixos`, make the file writable for your user, e.g. via
  a `wheel` group).

## Usage

Open the panel from the launcher by typing `/hamra` and picking an entry, or
with the IPC command above. The home screen shows the icon-function menu:

- **Aplicativos** — every `hamra.programs.*` boolean as a switch, grouped by
  tier (`optionals`, `core`) and category, read from the real `nix eval` of the
  flake, with a name filter. Flipping a switch writes the delta into
  `hosts/<host>/configuration.nix` (long form `programs.<key>` first, short key
  as fallback, ambiguity refused); the `Rebuild (n)` button then runs
  `nixos-rebuild switch`.
- **Instalar** — search Flathub (`flatpak search`) and install results, or
  create a web app: it downloads the site icon (apple-touch-icon, fallback
  apple-touch-icon.png, Google favicons) and writes a `.desktop` entry launching
  the browser with `--app=<url>`.
- **Remover** — installed Flatpaks (system and user scope) and web apps created
  by the plugin (removes the `.desktop` and the downloaded icon).
- **Atualizar** — `nix flake update` + rebuild, or rebuild switch/boot.
- **Chaves** — SSH and GPG grouped: generate an ed25519 key from an e-mail,
  copy public keys, load the agent, edit `~/.ssh/config`; generate/list GPG
  keys, set the git signing key, edit `gpg-agent.conf`.
- **Sistema** — host info (kernel, NixOS version, uptime, current generation),
  list generations, `nix-collect-garbage -d`, edit the host's
  `configuration.nix`, and rollback to the previous generation (two-step
  confirm).

Long-running actions (rebuild, `ssh-keygen`, flatpak install/uninstall, GC)
spawn in a terminal because they need your sudo password.

## Settings

This plugin exposes no settings.

## Notes

- The panel never runs `sudo` by itself; it only opens a terminal for those
  commands.
- Web apps land in `~/.local/share/applications/*.desktop` with icons under
  `~/.local/share/icons/hicolor/256x256/apps`.
- Environment overrides: `HAMRA_REPO` (default `/etc/nixos`) and `HAMRA_HOST`
  (default: the machine hostname) change which flake host is inspected.
