# Hamra Control

Control center for the Hamra (NixOS) config, inside Noctalia. It lists the
`hamra.programs.*` toggles with their real eval state, groups SSH and GPG key
tasks in one place, installs and removes Flatpaks, nix profile packages and
web apps behind a live preview pane, runs flake updates and rebuilds, and
exposes common system chores — replacing the old terminal `hamra-menu`.

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

Or bind a key to the same command (Hamra binds `Alt+Space` next to the other
plugin keybinds).

## Requirements

- A Hamra host checkout at `/etc/nixos` (or set `HAMRA_REPO` to the repo path).
- `nix` on `PATH` for reading the toggles via `nix eval`, for
  `nix search`/`nix profile` and for rebuilds.
- `flatpak` for the Instalar/Remover views.
- Write access to `hosts/<host>/configuration.nix` for the toggle switches (when
  the repo lives in `/etc/nixos`, make the file writable for your user, e.g. via
  a `wheel` group).

## Usage

Open the panel from the launcher by typing `/hamra` and picking an entry, or
with the IPC command above. The home screen shows the menu as a grid of cards:

- **Aplicativos** — every `hamra.programs.*` boolean as a switch, grouped by
  tier (`optionals`, `core`) and category, read from the real `nix eval` of the
  flake, with a name filter. Flipping a switch writes the delta into
  `hosts/<host>/configuration.nix` (long form `programs.<key>` first, short key
  as fallback, ambiguity refused); the `Rebuild (n)` button then runs
  `nixos-rebuild switch`.
- **Instalar** — three tabs, each with a list on the left and a preview pane on
  the right (the old `fzf --preview 'flatpak remote-info …'` view):
  - **Flatpak** — search Flathub (`flatpak search`), the preview runs
    `flatpak remote-info flathub <id>`, and installing opens a terminal for the
    sudo password. Results already on the system are marked *instalado*.
  - **Nix** — search nixpkgs (`nix search … --json`, ranked by name/attr match)
    with description, version and attribute in the preview; installing runs
    `nix profile install nixpkgs#<attr>` (no sudo, opens in the terminal so you
    can watch the build).
  - **Web app** — it downloads the site icon (apple-touch-icon, fallback
    apple-touch-icon.png, Google favicons) and writes a `.desktop` entry
    launching the browser with `--app=<url>`.
- **Remover** — same three tabs for things that are installed: Flatpaks (system
  and user scope, preview via `flatpak info`, system scope goes through a
  terminal with sudo), nix profile packages (preview shows attribute, origin,
  version and store path; removal runs `nix profile remove <name>` and refreshes
  the list), and web apps created by the plugin (removes the `.desktop` and the
  downloaded icon). Hover or click a row to preview it, then use the red
  **Remover** button in the pane.
- **Atualizar** — `nix flake update` + rebuild, or rebuild switch/boot.
- **Chaves** — SSH and GPG grouped: generate an ed25519 key from an e-mail,
  copy public keys, load the agent, edit `~/.ssh/config`; generate/list GPG
  keys, set the git signing key, edit `gpg-agent.conf`.
- **Sistema** — host info (kernel, NixOS version, uptime, current generation),
  list generations, `nix-collect-garbage -d`, edit the host's
  `configuration.nix`, and rollback to the previous generation (two-step
  confirm).

Long-running actions (rebuild, `ssh-keygen`, flatpak install, nix profile
install, GC) spawn in a terminal so you can follow the progress — those that
need your sudo password keep it out of the panel.

## IPC

Every entry accepts events, which is handy for keybinds and scripts:

```sh
noctalia msg plugin gabrielnathan929/hamra-control:main all view install
noctalia msg plugin gabrielnathan929/hamra-control:main all tab install:nix
noctalia msg plugin gabrielnathan929/hamra-control:main all search nix ripgrep
noctalia msg plugin gabrielnathan929/hamra-control:main all select nx:ripgrep
```

`view` takes `home|apps|install|remove|update|keys|system`, `tab` takes
`<view>:<tab>`, `search` runs a search on `flatpak` or `nix`, and `select`
selects a row by key (`fl:`, `nx:`, `ifl:`, `inx:`, `web:`) so the preview
loads.

## Settings

This plugin exposes no settings.

## Notes

- The panel never runs `sudo` by itself; it only opens a terminal for those
  commands.
- Packages installed from the **Nix** tab land in your user profile
  (`nix profile`), not in `configuration.nix`: they survive rebuilds but are
  imperative. Declarative apps stay in **Aplicativos** (`hamra.programs.*`).
- Web apps land in `~/.local/share/applications/*.desktop` with icons under
  `~/.local/share/icons/hicolor/256x256/apps`.
- Environment overrides: `HAMRA_REPO` (default `/etc/nixos`) and `HAMRA_HOST`
  (default: the machine hostname) change which flake host is inspected.
