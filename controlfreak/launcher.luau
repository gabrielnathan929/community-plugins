--!nonstrict

local PANEL_ID = "gabrielnathan929/controlfreak:main"

local MENU = {
  { id = "apps", label = "Aplicativos", glyph = "app-window", sub = "Toggles do hamra.programs" },
  { id = "install", label = "Instalar", glyph = "download", sub = "Flatpak, nix, mise e web apps" },
  { id = "remove", label = "Remover", glyph = "trash", sub = "Flatpak, nix, mise e web apps" },
  { id = "update", label = "Atualizar", glyph = "refresh", sub = "flake update, mise e rebuild" },
  { id = "keys", label = "Chaves", glyph = "key", sub = "SSH e GPG" },
  { id = "system", label = "Sistema", glyph = "settings", sub = "Info, gerações, GC, rollback" },
}

local function trim(s)
  return noctalia.string.trim(s or "")
end

function onQuery(query)
  local text = trim(query)
  local rows = {}

  if text == "" then
    for _, entry in ipairs(MENU) do
      rows[#rows + 1] = {
        id = "open:" .. entry.id,
        title = entry.label,
        subtitle = entry.sub,
        glyph = entry.glyph,
      }
    end
  else
    for _, entry in ipairs(MENU) do
      local score = noctalia.fuzzyScore(text, entry.label)
      if score ~= nil then
        rows[#rows + 1] = {
          id = "open:" .. entry.id,
          title = entry.label,
          subtitle = entry.sub,
          glyph = entry.glyph,
        }
      end
    end
    if #rows == 0 then
      rows[#rows + 1] = {
        id = "search-flathub:" .. text,
        title = "Buscar '" .. text .. "' no Flathub",
        subtitle = "Abre ControlFreak › Instalar › Flatpak",
        glyph = "box",
      }
      rows[#rows + 1] = {
        id = "search-nix:" .. text,
        title = "Buscar '" .. text .. "' no nixpkgs",
        subtitle = "Abre ControlFreak › Instalar › Nix",
        glyph = "package",
      }
      rows[#rows + 1] = {
        id = "search-mise:" .. text,
        title = "Buscar '" .. text .. "' no mise",
        subtitle = "Abre ControlFreak › Instalar › Mise",
        glyph = "tool",
      }
    end
  end

  launcher.setResults(query, rows)
end

function onActivate(id)
  local viewId = id:match("^open:(.+)$")
  if viewId ~= nil then
    noctalia.state.set("hamra_view", viewId)
    noctalia.togglePanel(PANEL_ID)
    return
  end

  local q = id:match("^search%-flathub:(.+)$")
  if q ~= nil then
    noctalia.state.set("hamra_install_query", trim(q))
    noctalia.togglePanel(PANEL_ID)
    return
  end

  local n = id:match("^search%-nix:(.+)$")
  if n ~= nil then
    noctalia.state.set("hamra_install_tab", "nix")
    noctalia.state.set("hamra_install_query", trim(n))
    noctalia.togglePanel(PANEL_ID)
    return
  end

  local m = id:match("^search%-mise:(.+)$")
  if m ~= nil then
    noctalia.state.set("hamra_install_tab", "mise")
    noctalia.state.set("hamra_install_query", trim(m))
    noctalia.togglePanel(PANEL_ID)
  end
end
