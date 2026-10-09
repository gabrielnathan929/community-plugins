# ControlFreak

Control center for the Hamra (NixOS) config, inside Noctalia. It lists the
`hamra.programs.*` toggles with their real eval state, groups SSH and GPG key
tasks in one place, installs and removes Flatpaks, nix profile packages, mise
tools and web apps behind a live preview pane, runs flake updates, upgrades mise
tools and exposes common system chores — replacing the old terminal `hamra-menu`.

## Plugin

| Field | Value |
| --- | --- |
| ID | `gabrielnathan929/controlfreak` |
| Entries | panel: `main`; widget: `control`; launcher provider: `menu` |
| Launcher Prefix | `/controlfreak` |

Open the panel with:

```sh
noctalia msg panel-toggle gabrielnathan929/controlfreak:main
```

Or bind a key to the same command (Hamra binds `Alt+Space` next to the other
plugin keybinds).

### Bar widget

Add the **control** widget to any bar (Settings → Bar → Add Widget): left click
opens the panel, right click jumps straight to the **Instalar** view with a
search ready.

## Requirements

- A Hamra host checkout at `/etc/nixos` (or set `HAMRA_REPO` to the repo path).
- `nix` on `PATH` for reading the toggles via `nix eval`, for
  `nix search`/`nix profile` and for rebuilds.
- `flatpak` for the Flatpak tabs of Instalar/Remover.
- `mise` for the Mise tabs (Instalar › Mise, Remover › Mise) and the mise
  upgrades in Atualizar.
- Write access to `hosts/<host>/configuration.nix` for the toggle switches (when
  the repo lives in `/etc/nixos`, make the file writable for your user, e.g. via
  a `wheel` group).

## Usage

Open the panel from the launcher by typing `/controlfreak` and picking an entry, or
with the IPC command above. The home screen shows the menu as a grid of cards:

- **Aplicativos** — every `hamra.programs.*` boolean as a switch, grouped by
  tier (`optionals`, `core`) and category, read from the real `nix eval` of the
  flake, with a name filter. Flipping a switch edits the value in place in
  `hosts/<host>/configuration.nix` (every toggle is already there, true or
  false); the `Rebuild (n)` button then runs `nixos-rebuild switch`.
- **Instalar** — four tabs, each with a list on the left and a preview pane on
  the right (the old `fzf --preview 'flatpak remote-info …'` view). Results
  appear as you type (debounced); Enter or Buscar searches immediately:
  - **Flatpak** — search Flathub (`flatpak search`), the preview runs
    `flatpak remote-info flathub <id>`, and installing opens a terminal for the
    sudo password. Results already on the system are marked *instalado*.
  - **Nix** — search nixpkgs (`nix search … --json`, ranked by name/attr match)
    with description, version and attribute in the preview; installing runs
    `nix profile install nixpkgs#<attr>` (no sudo, opens in the terminal so you
    can watch the build).
  - **Mise** — search the mise registry (`mise search`) with description in the
    preview; installing runs `mise use -g <tool>@latest`, which pins the tool to
    always-latest in the global `~/.config/mise/config.toml`. Tools already
    managed by mise are marked *instalado*.
  - **Web app** — it writes the `.desktop` entry right away (generic icon) so
    the launcher gets it immediately, then upgrades `Icon=` asynchronously with
    the site icon (apple-touch-icon, fallback apple-touch-icon.png, Google
    favicons); it launches the browser with `--app=<url>`.
- **Remover** — the same tabs for things that are installed: Flatpaks (system
  and user scope, preview via `flatpak info`, system scope goes through a
  terminal with sudo), nix profile packages (preview shows attribute, origin,
  version and store path; removal runs `nix profile remove <name>` and refreshes
  the list), mise tools (preview shows installed and requested version; removal
  runs `mise unuse -g <tool>` followed by `mise uninstall`), and web apps: the
  ones created by the plugin (removes the `.desktop` and the downloaded icon)
  plus the ones declared in Nix (`hamra.webapps`, read from
  `/etc/hamra/apps.json`) marked with a **nix** badge — those are declarative,
  so the pane explains how to remove them instead of offering a delete button.
  Hover or click a row to preview it, then use the red **Remover** button in the
  pane.
- **Atualizar** — a list with the system tasks (`nix flake update` + rebuild,
  rebuild switch, rebuild boot) and every mise tool with `installed → latest`
  from `mise outdated --json`; hovering a row shows the exact command in the
  preview pane, where a button runs it (each opens a terminal so you can follow
  the output).
- **Chaves** — SSH and GPG grouped: generate an ed25519 key from an e-mail,
  copy public keys, load the agent, edit `~/.ssh/config`; generate/list GPG
  keys, set the git signing key, edit `gpg-agent.conf`. Private keys can be
  pasted and imported: SSH goes to `~/.ssh` (700/600/644, `.pub` derived,
  `ssh-add`, `ssh -T git@github.com` test shown); GPG goes through
  `gpg --import` (ownertrust ultimate, clearsign round-trip test shown).
- **Sistema** — host info card (kernel, NixOS version, uptime, current
  generation) plus a task list (list generations, `nix-collect-garbage -d`, edit
  the host's `configuration.nix`, and rollback to the previous generation with a
  two-step confirm), each task showing its command and effect in the preview
  pane before you run it.

Long-running actions (rebuild, `ssh-keygen`, flatpak install, nix profile
install, `mise use`/`mise upgrade`, GC) spawn in a terminal so you can follow
the progress — those that need your sudo password keep it out of the panel.

## IPC

Every entry accepts events, which is handy for keybinds and scripts:

```sh
noctalia msg plugin gabrielnathan929/controlfreak:main all view install
noctalia msg plugin gabrielnathan929/controlfreak:main all tab install:nix
noctalia msg plugin gabrielnathan929/controlfreak:main all search nix ripgrep
noctalia msg plugin gabrielnathan929/controlfreak:main all search mise node
noctalia msg plugin gabrielnathan929/controlfreak:main all select nx:ripgrep
noctalia msg plugin gabrielnathan929/controlfreak:main all select upd:flake
noctalia msg plugin gabrielnathan929/controlfreak:main all webapp-create Notes https://notes.example.com
noctalia msg plugin gabrielnathan929/controlfreak:main all webapp-remove Notes.desktop
```

`view` takes `home|apps|install|remove|update|keys|system`, `tab` takes
`<view>:<tab>`, `search` runs a search on `flatpak`, `nix` or `mise`, and
`select` selects a row by key (`fl:`, `nx:`, `mx:`, `ifl:`, `inx:`, `imx:`,
`web:`, `upd:`, `sys:`, `mo:`, `webnix:`) so the preview loads.
`webapp-create` creates an imperative web app (same flow as the button) and
`webapp-remove` deletes one by `.desktop` file or name (Nix-declared web apps
are not removable this way).

## Settings

Bar widget settings (per widget instance):

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `glyph` | glyph | `adjustments` | Icon shown in the bar. |
| `show_label` | bool | `false` | Show the text next to the icon. |
| `label` | string | `ControlFreak` | Text shown when `show_label` is on. |

## Notes

- The panel never runs `sudo` by itself; it only opens a terminal for those
  commands.
- Packages installed from the **Nix** tab land in your user profile
  (`nix profile`), not in `configuration.nix`: they survive rebuilds but are
  imperative. Declarative apps stay in **Aplicativos** (`hamra.programs.*`).
- Tools installed from the **Mise** tab live in `~/.config/mise/config.toml`
  (`mise use -g …@latest`) and inside the shell the mise shims take PATH
  precedence over the Nix store; daemons and services keep using the Nix
  version.
- Web apps land in `~/.local/share/applications/*.desktop` with icons under
  `~/.local/share/icons/hicolor/256x256/apps`.
- Environment overrides: `HAMRA_REPO` (default `/etc/nixos`) and `HAMRA_HOST`
  (default: the machine hostname) change which flake host is inspected.
