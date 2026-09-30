--!nonstrict

-- Hamra Control — painel de controle do Hamra (NixOS) dentro do Noctalia.
--
-- Home: menu em grade com as seis áreas do painel. Instalar e Remover cobrem
-- Flatpak, pacotes nix (nix profile) e web apps, sempre com o painel de
-- preview lateral no estilo do antigo `fzf --preview 'flatpak remote-info'`.
-- O delta dos toggles vai para hosts/<host>/configuration.nix.

local home = noctalia.getenv("HOME") or "~"

local repo = noctalia.getenv("HAMRA_REPO")
if repo == nil or repo == "" then
  repo = "/etc/nixos"
end

local host = noctalia.getenv("HAMRA_HOST")
if host == nil or host == "" then
  local h = noctalia.readFile("/etc/hostname")
  host = (type(h) == "string" and noctalia.string.trim(h) ~= "") and noctalia.string.trim(h) or ""
end
if host == "" then
  noctalia.runAsync("hostname", function(res)
    if res.exitCode == 0 and noctalia.string.trim(res.stdout or "") ~= "" then
      host = noctalia.string.trim(res.stdout)
    end
  end)
end

local browserExec = "chromium"
noctalia.runAsync("command -v chromium || command -v helium || command -v google-chrome || command -v chromium-browser", function(res)
  if res.exitCode == 0 then
    local line = noctalia.string.trim((res.stdout or ""):match("[^\r\n]+") or "")
    if line ~= "" then browserExec = line end
  end
end)

local editorExec = noctalia.getenv("EDITOR")
if editorExec == nil or editorExec == "" then editorExec = "nvim" end

-- ── helpers ─────────────────────────────────────────────────────────────────

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function splitLines(s)
  local t = {}
  for line in (s or ""):gmatch("[^\r\n]+") do
    table.insert(t, line)
  end
  return t
end

local function escapePattern(s)
  return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%1"))
end

local function iconDir()
  return home .. "/.local/share/icons/hicolor/256x256/apps"
end

local function desktopDir()
  return home .. "/.local/share/applications"
end

local function notify(text)
  noctalia.notify("Hamra Control", text)
end

local function notifyError(text)
  noctalia.notifyError("Hamra Control", text)
end

-- declarações adiantadas (usadas por funções definidas antes delas)
local render
local openView
local selectItem
local selectByKey

local view = "home"

local MENU = {
  { id = "apps", label = "Aplicativos", glyph = "app-window", sub = "Toggles do hamra.programs" },
  { id = "install", label = "Instalar", glyph = "download", sub = "Flatpak, nix e web apps" },
  { id = "remove", label = "Remover", glyph = "trash", sub = "Flatpak, nix e web apps" },
  { id = "update", label = "Atualizar", glyph = "refresh", sub = "flake update e rebuild" },
  { id = "keys", label = "Chaves", glyph = "key", sub = "SSH e GPG" },
  { id = "system", label = "Sistema", glyph = "settings", sub = "Info, gerações, GC, rollback" },
}

local function runInTerminal(cmd)
  if not noctalia.runInTerminal(cmd) then
    notifyError("Não consegui abrir um terminal.")
    return false
  end
  return true
end

-- ── shared UI ───────────────────────────────────────────────────────────────

local function header(title, actions)
  local children = {
    ui.button({ glyph = "arrow-left", variant = "ghost", tooltip = "Voltar", onClick = "onBack" }),
    ui.label({ text = title, fontSize = 16, fontWeight = "bold", flexGrow = 1, maxLines = 1 }),
  }
  for _, a in ipairs(actions or {}) do
    table.insert(children, a)
  end
  table.insert(children, ui.button({ glyph = "close", variant = "ghost", tooltip = "Fechar", onClick = function() panel.close() end }))
  return ui.row({ align = "center", gap = 8 }, children)
end

-- Barra de abas: items = { { id, label, glyph } }
local function tabsBar(items, activeId, onPick)
  local children = {}
  for _, it in ipairs(items) do
    local active = it.id == activeId
    table.insert(children, ui.button({
      key = "tab-" .. it.id,
      text = it.label,
      glyph = it.glyph,
      variant = active and "primary" or "outline",
      selected = active,
      flexGrow = 1,
      height = 34,
      onClick = function() onPick(it.id) end,
    }))
  end
  return ui.row({ gap = 8, align = "center" }, children)
end

-- Lista à esquerda + preview à direita (o preview do antigo fzf/gum).
local function splitPane(listChildren, previewChildren, previewWidth)
  return ui.row({ flexGrow = 1, gap = 12, align = "stretch" }, {
    ui.scroll({ flexGrow = 1, gap = 6 }, listChildren),
    ui.column({
      width = previewWidth or 264,
      gap = 8,
      padding = 14,
      paddingV = 12,
      fill = "surface",
      radius = 10,
      border = "outline",
      borderWidth = 1,
    }, previewChildren),
  })
end

local function hint(text)
  return ui.label({ text = text, fontSize = 10, color = "on_surface_variant", maxLines = 2 })
end

local function statusLine(text)
  if text == nil or text == "" then
    return ui.label({ text = " ", fontSize = 10, color = "on_surface_variant" })
  end
  return ui.label({ text = text, fontSize = 10, color = "on_surface_variant", maxLines = 3 })
end

-- ── Aplicativos (toggles do flake) ──────────────────────────────────────────

local appsLoaded = false
local appsLoading = false
local appsError = nil
local tiers = {}
local pending = {}
local appFilter = ""

local function loadApps()
  appsLoading = true
  appsError = nil
  pending = {}
  render()
  local cmd = "nix eval " .. shq(repo .. "#nixosConfigurations." .. host .. ".config.hamra.programs") .. " --json"
  noctalia.runAsync(cmd, function(res)
    appsLoading = false
    if res.exitCode ~= 0 then
      appsError = "nix eval falhou: " .. trim(res.stderr):sub(1, 300)
      render()
      return
    end
    local ok, data = pcall(noctalia.json.decode, res.stdout or "")
    if not ok or type(data) ~= "table" then
      appsError = "JSON inválido do nix eval"
      render()
      return
    end
    local newTiers = {}
    for _, tier in ipairs({ "optionals", "core" }) do
      local cats = data[tier]
      if type(cats) == "table" then
        local catNames = {}
        for c in pairs(cats) do
          table.insert(catNames, c)
        end
        table.sort(catNames)
        local catList = {}
        for _, c in ipairs(catNames) do
          local items = {}
          for n, v in pairs(cats[c]) do
            if type(v) == "boolean" then
              table.insert(items, { key = tier .. "." .. c .. "." .. n, name = n, value = v })
            end
          end
          table.sort(items, function(a, b)
            return a.name < b.name
          end)
          if #items > 0 then
            table.insert(catList, { name = c, items = items })
          end
        end
        if #catList > 0 then
          table.insert(newTiers, { name = tier, cats = catList })
        end
      end
    end
    tiers = newTiers
    appsLoaded = true
    render()
  end, 60000)
end

local function setToggleInConfig(key, want)
  local path = repo .. "/hosts/" .. host .. "/configuration.nix"
  local content = noctalia.readFile(path)
  if type(content) ~= "string" or content == "" then
    return false, "não consegui ler " .. path
  end

  local boolWord = want and "true" or "false"
  local count = 0

  local function applyPattern(pat)
    content = content:gsub(pat, function(pre)
      count += 1
      return pre .. boolWord .. ";"
    end)
  end

  applyPattern("\n([ \t]*programs%." .. escapePattern(key) .. "[ \t]*=[ \t]*)(true|false)(;)")

  if count == 0 then
    applyPattern("\n([ \t]*[\"']?" .. escapePattern(key:match("[^%.]+$")) .. "[\"']?[ \t]*=[ \t]*)(true|false)(;)")
  end

  if count > 1 then
    return false, "'" .. key .. "' aparece " .. count .. " vezes em " .. path .. " (edite à mão)"
  end

  if count == 0 then
    local pos = content:find("\n[ \t]*hamra[ \t]*=[ \t]*(lib%.mkDefault[ \t]*)?{")
    if pos == nil then
      return false, "bloco hamra = { ... } não encontrado em " .. path
    end
    local lineEnd = content:find("\n", pos + 1)
    if lineEnd == nil then
      return false, "bloco hamra malformado em " .. path
    end
    content = content:sub(1, lineEnd)
      .. "    programs." .. key .. " = " .. boolWord .. ";\n"
      .. content:sub(lineEnd + 1)
  end

  noctalia.writeFile(path, content)

  local check = noctalia.readFile(path)
  if type(check) ~= "string"
    or not check:find("programs%." .. escapePattern(key) .. "[ \t]*=[ \t]*" .. boolWord) then
    return false, "não consegui escrever " .. path .. " (permissão?)"
  end
  return true
end

local function toggleItem(item, v)
  local want = (v == true or v == "true")
  if want == item.value then
    return
  end
  local ok, err = setToggleInConfig(item.key, want)
  if not ok then
    notifyError(tostring(err))
    loadApps()
    return
  end
  item.value = want
  pending[item.key] = want
  render()
end

local function pendingCount()
  local n = 0
  for _ in pairs(pending) do
    n += 1
  end
  return n
end

local function runRebuild(mode)
  local cmd = "cd " .. shq(repo)
    .. " && sudo nixos-rebuild " .. mode
    .. " --flake " .. shq(repo .. "#" .. host)
  if runInTerminal(cmd) then
    notify("Rebuild (" .. mode .. ") disparado no terminal.")
  end
end

function onRebuildSwitch()
  runRebuild("switch")
  pending = {}
  render()
end

local function renderApps()
  local actions = {}
  local n = pendingCount()
  if n > 0 then
    table.insert(actions, ui.button({
      text = "Rebuild (" .. n .. ")",
      glyph = "refresh",
      variant = "primary",
      onClick = "onRebuildSwitch",
    }))
  end
  table.insert(actions, ui.button({ glyph = "reload", variant = "ghost", tooltip = "Recarregar do eval", onClick = "onAppsReload" }))

  local children = { header("Aplicativos", actions) }

  table.insert(children, ui.input({
    key = "app-filter",
    value = appFilter,
    placeholder = "Filtrar por nome...",
    onChange = function(v)
      appFilter = v or ""
      render()
    end,
  }))

  if appsLoading then
    table.insert(children, ui.scroll({ flexGrow = 1 }, {
      ui.label({ text = "Avaliando hamra.programs de " .. host .. "...", color = "on_surface_variant" }),
    }))
  elseif appsError ~= nil then
    table.insert(children, ui.column({ gap = 10 }, {
      ui.label({ text = appsError, color = "error", maxLines = 4 }),
      ui.button({ text = "Tentar de novo", variant = "primary", onClick = "onAppsReload" }),
    }))
  else
    local filter = appFilter:lower()
    local sections = {}
    for _, tier in ipairs(tiers) do
      local tierBlock = { ui.label({ text = tier.name, fontSize = 14, fontWeight = "bold", color = "primary" }) }
      for _, cat in ipairs(tier.cats) do
        local rows = {}
        for _, item in ipairs(cat.items) do
          if filter == "" or item.name:lower():find(filter, 1, true) ~= nil then
            table.insert(rows, ui.row({
              key = "tg-" .. item.key,
              align = "center",
              gap = 10,
            }, {
              ui.label({ text = item.name, flexGrow = 1, maxLines = 1, fontSize = 13 }),
              ui.toggle({ checked = item.value, onChange = function(v) toggleItem(item, v) end }),
            }))
          end
        end
        if #rows > 0 then
          table.insert(tierBlock, ui.label({ text = cat.name, fontSize = 11, color = "on_surface_variant" }))
          for _, r in ipairs(rows) do
            table.insert(tierBlock, r)
          end
          table.insert(tierBlock, ui.separator({ spacing = 6 }))
        end
      end
      table.insert(sections, ui.column({ gap = 6 }, tierBlock))
    end
    if #sections == 0 then
      table.insert(children, ui.label({ text = "Nenhum toggle encontrado.", color = "on_surface_variant" }))
    else
      table.insert(children, ui.scroll({ flexGrow = 1, gap = 12 }, sections))
    end
  end

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── Chaves (SSH + GPG) ──────────────────────────────────────────────────────

local sshEmail = ""
local sshPubs = {}

local function loadSshPubs()
  sshPubs = {}
  local entries = noctalia.listDir(home .. "/.ssh")
  if type(entries) ~= "table" then
    return
  end
  table.sort(entries)
  for _, name in ipairs(entries) do
    if name:match("%.pub$") then
      table.insert(sshPubs, name)
    end
  end
end

local gpgListText = nil
local gpgBusy = false

local function copySshPub(name)
  local content = noctalia.readFile(home .. "/.ssh/" .. name)
  if type(content) ~= "string" or trim(content) == "" then
    notifyError("Não consegui ler " .. name)
    return
  end
  noctalia.copyToClipboard(trim(content), "text/plain")
  notify(name .. " copiado para o clipboard.")
end

local function sshGenerate()
  local email = trim(sshEmail)
  if email == "" then
    notifyError("Preencha o e-mail do comentário da chave.")
    return
  end
  local keyPath = home .. "/.ssh/id_ed25519"
  if noctalia.fileExists(keyPath) then
    notifyError("Já existe " .. keyPath)
    return
  end
  runInTerminal("mkdir -p ~/.ssh && chmod 700 ~/.ssh && ssh-keygen -t ed25519 -C " .. shq(email) .. " -f " .. shq(keyPath))
end

local function setGitSigning()
  gpgBusy = true
  render()
  noctalia.runAsync("gpg --list-secret-keys --keyid-format LONG", function(res)
    gpgBusy = false
    local keyId = (res.stdout or ""):match("sec%s+%a+[%a%d]*/(%x+)")
    if keyId == nil then
      notifyError("Nenhuma chave secreta GPG encontrada. Gere uma primeiro.")
      render()
      return
    end
    noctalia.runAsync("git config --global user.signingkey " .. shq(keyId) .. " && git config --global commit.gpgsign true", function(res2)
      if res2.exitCode == 0 then
        notify("Git signing key definida: " .. keyId)
      else
        notifyError("git config falhou: " .. trim(res2.stderr))
      end
      render()
    end)
  end)
end

local function renderKeys()
  local children = { header("Chaves", {}) }

  local sshBlock = {
    ui.label({ text = "SSH", fontSize = 14, fontWeight = "bold", color = "primary" }),
    ui.row({ align = "center", gap = 8 }, {
      ui.input({
        key = "ssh-email",
        value = sshEmail,
        placeholder = "e-mail para o comentário da chave",
        flexGrow = 1,
        onChange = function(v) sshEmail = v or "" end,
      }),
      ui.button({ text = "Gerar ed25519", glyph = "plus", onClick = "onSshGenerate" }),
    }),
    ui.row({ align = "center", gap = 8 }, {
      ui.button({ text = "Copiar chave pública", glyph = "copy", onClick = "onSshCopyDefault" }),
      ui.button({ text = "Add ao agent", glyph = "key", onClick = "onSshAgent" }),
      ui.button({ text = "Editar config", glyph = "edit", onClick = "onSshEditConfig" }),
    }),
  }
  if #sshPubs == 0 then
    table.insert(sshBlock, ui.label({ text = "Nenhuma chave *.pub em ~/.ssh", fontSize = 11, color = "on_surface_variant" }))
  else
    for _, name in ipairs(sshPubs) do
      table.insert(sshBlock, ui.row({ align = "center", gap = 8, key = "ssh-" .. name }, {
        ui.glyph({ name = "key", size = 13 }),
        ui.label({ text = name, flexGrow = 1, maxLines = 1, fontSize = 12 }),
        ui.button({ glyph = "copy", variant = "ghost", tooltip = "Copiar", onClick = function() copySshPub(name) end }),
      }))
    end
  end

  local gpgBlock = {
    ui.label({ text = "GPG", fontSize = 14, fontWeight = "bold", color = "primary" }),
    ui.row({ align = "center", gap = 8 }, {
      ui.button({ text = "Gerar chave", glyph = "plus", onClick = "onGpgGenerate" }),
      ui.button({ text = "Listar chaves", glyph = "list-search", onClick = "onGpgList" }),
      ui.button({ text = "Set git signing", glyph = "check", onClick = "onGpgGitSign", enabled = not gpgBusy }),
      ui.button({ text = "gpg-agent.conf", glyph = "edit", onClick = "onGpgEditAgent" }),
    }),
  }
  if gpgListText ~= nil then
    table.insert(gpgBlock, ui.label({ text = gpgListText, fontSize = 11, maxLines = 18, color = "on_surface_variant" }))
  end

  table.insert(children, ui.column({ gap = 8 }, sshBlock))
  table.insert(children, ui.separator({ spacing = 4 }))
  table.insert(children, ui.column({ gap = 8 }, gpgBlock))
  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── seleção + preview (compartilhado entre Instalar e Remover) ─────────────

local selected = nil -- item { key, kind, name, ... }
local preview = nil -- { loading?: true, text?: string }
local actionStatus = nil

-- Linhas de commit/hash poluem o preview; o resto é o mesmo texto cru que o
-- antigo `fzf --preview 'flatpak remote-info ...'` mostrava.
local HEX_RUN = string.rep("%x", 24)

local function trimInfo(text)
  local out = {}
  for _, line in ipairs(splitLines(text)) do
    local t = trim(line)
    if t ~= "" and not line:find(HEX_RUN) then
      out[#out + 1] = line
      if #out >= 14 then
        break
      end
    end
  end
  return table.concat(out, "\n")
end

local function resetSelection()
  selected = nil
  preview = nil
end

local function loadPreviewFor(item)
  if item.kind == "nix" then
    local lines = {}
    if item.desc ~= nil and item.desc ~= "" then
      table.insert(lines, item.desc)
    end
    if item.version ~= nil and item.version ~= "" then
      table.insert(lines, "")
      table.insert(lines, "Versão: " .. item.version)
    end
    table.insert(lines, "Attr: " .. (item.attr or item.name))
    preview = { text = table.concat(lines, "\n") }
    return
  end

  if item.kind == "nixInstalled" then
    local lines = {}
    table.insert(lines, "Perfil: nix profile")
    if item.attr ~= nil and item.attr ~= "" then
      table.insert(lines, "Attr: " .. item.attr)
    end
    if item.origin ~= nil and item.origin ~= "" then
      table.insert(lines, "Origem: " .. item.origin)
    end
    if item.version ~= nil and item.version ~= "" then
      table.insert(lines, "Versão: " .. item.version)
    end
    if item.store ~= nil and item.store ~= "" then
      table.insert(lines, "")
      table.insert(lines, item.store)
    end
    preview = { text = table.concat(lines, "\n") }
    return
  end

  if item.kind == "web" then
    preview = { text = table.concat({
      "Web app do navegador",
      "",
      "URL: " .. (item.url or ""),
      "Arquivo: " .. (item.file or ""),
      "Ícone: " .. (item.icon or "-"),
      "",
      "Abre em modo app (--app) no navegador detectado.",
    }, "\n") }
    return
  end

  local cmd
  if item.kind == "flatpak" then
    cmd = "flatpak remote-info flathub " .. shq(item.id)
  else
    local scopeFlag = item.scope == "user" and "--user " or "--system "
    cmd = "flatpak info " .. scopeFlag .. shq(item.id)
  end

  preview = { loading = true }
  local wanted = item.key
  noctalia.runAsync(cmd, function(res)
    if selected == nil or selected.key ~= wanted then
      return
    end
    local text = trimInfo((res.exitCode == 0 and res.stdout or res.stderr) or "")
    preview = { text = text ~= "" and text or "Sem detalhes disponíveis." }
    render()
  end, 30000)
end

selectItem = function(item)
  if selected ~= nil and selected.key == item.key then
    return
  end
  selected = item
  preview = nil
  loadPreviewFor(item)
  render()
end

local function itemBadge(item)
  if item.kind == "flatpak" and item.installed then
    return "instalado"
  end
  if item.kind == "nix" and item.installed then
    return "instalado"
  end
  if item.kind == "flatpakInstalled" then
    return item.scope == "user" and "user" or "system"
  end
  return nil
end

local function itemRow(item)
  local active = selected ~= nil and selected.key == item.key
  local children = {}

  local titleRow = {
    ui.label({ text = item.name, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1 }),
  }
  if item.version ~= nil and item.version ~= "" then
    table.insert(titleRow, ui.label({ text = item.version, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))
  end
  local badge = itemBadge(item)
  if badge ~= nil then
    table.insert(titleRow, ui.label({ text = badge, fontSize = 9, fontWeight = "bold", color = "primary", maxLines = 1 }))
  end
  table.insert(children, ui.row({ gap = 8, align = "center" }, titleRow))

  local sub = item.id or item.attr or item.url or item.store or ""
  if item.desc ~= nil and item.desc ~= "" then
    sub = sub .. "  ·  " .. item.desc
  end
  table.insert(children, ui.label({ text = sub, fontSize = 10, color = "on_surface_variant", maxLines = 1 }))

  return ui.column({
    key = item.key,
    gap = 2,
    padding = 7,
    paddingH = 10,
    fill = active and "primary/0.12" or "surface",
    radius = 8,
    flexGrow = 1,
    onHover = function(state)
      if state == "true" then
        selectItem(item)
      end
    end,
    onClick = function()
      selectItem(item)
    end,
  }, children)
end

-- opts: { action = { label, glyph, enabled, onClick }, empty = string }
local function selectionPane(opts)
  local children = {}

  if selected == nil then
    table.insert(children, ui.glyph({ name = "eye", size = 18, color = "on_surface_variant" }))
    table.insert(children, ui.label({
      text = opts.empty or "Passe o mouse ou clique num item para ver os detalhes aqui.",
      fontSize = 11,
      color = "on_surface_variant",
      maxLines = 5,
    }))
    return children
  end

  table.insert(children, ui.label({ text = selected.name, fontSize = 15, fontWeight = "bold", maxLines = 1 }))
  local meta = selected.id or selected.attr or selected.url or ""
  if meta ~= "" then
    table.insert(children, ui.label({ text = meta, fontSize = 10, color = "on_surface_variant", maxLines = 2 }))
  end

  if preview == nil then
    table.insert(children, ui.label({ text = "…", fontSize = 11, color = "on_surface_variant" }))
  elseif preview.loading then
    table.insert(children, ui.label({ text = "Buscando detalhes...", fontSize = 11, color = "on_surface_variant" }))
  else
    table.insert(children, ui.label({ text = preview.text, fontSize = 10, maxLines = 18 }))
  end

  table.insert(children, ui.spacer({ flexGrow = 1 }))

  if opts.action ~= nil then
    table.insert(children, ui.button({
      text = opts.action.label,
      glyph = opts.action.glyph,
      variant = opts.action.variant or "primary",
      enabled = opts.action.enabled ~= false,
      onClick = opts.action.onClick,
    }))
  end
  if opts.status ~= nil and opts.status ~= "" then
    table.insert(children, ui.label({ text = opts.status, fontSize = 10, color = "on_surface_variant", maxLines = 4 }))
  end

  return children
end

-- ── estado de instalação / remoção ──────────────────────────────────────────

local instTab = "flatpak" -- flatpak | nix | web
local removeTab = "flatpak" -- flatpak | nix | web

local flQuery = ""
local flResults = nil
local flSearching = false
local flError = nil

local nxQuery = ""
local nxResults = nil
local nxSearching = false
local nxError = nil

local installedFlat = {}
local installedNix = {}

local flatApps = nil
local flatLoading = false
local nixApps = nil
local nixLoading = false
local removeError = nil

local webApps = {}
local webAppsLoaded = false

selectByKey = function(key)
  local pool = {}
  if view == "install" then
    if instTab == "flatpak" then
      pool = flResults or {}
    else
      pool = nxResults or {}
    end
  elseif view == "remove" then
    if removeTab == "flatpak" then
      pool = flatApps or {}
    elseif removeTab == "nix" then
      pool = nixApps or {}
    else
      pool = webApps
    end
  end
  for _, item in ipairs(pool) do
    if item.key == key then
      selectItem(item)
      return
    end
  end
  -- fallback por prefixo (útil no CLI: `... all select fl:`)
  for _, item in ipairs(pool) do
    if item.key:find(key, 1, true) == 1 then
      selectItem(item)
      return
    end
  end
end

local function markInstalled()
  for _, item in ipairs(flResults or {}) do
    item.installed = installedFlat[item.id] == true
  end
  for _, item in ipairs(nxResults or {}) do
    item.installed = installedNix[item.name] == true
  end
end

local function loadInstalledSets()
  noctalia.runAsync(
    "flatpak list --system --app --columns=application 2>/dev/null; printf '\\n--user--\\n'; flatpak list --user --app --columns=application 2>/dev/null",
    function(res)
      installedFlat = {}
      for _, line in splitLines(res.stdout or "") do
        if line ~= "--user--" then
          local id = trim(line)
          if id ~= "" and id:find(".", 1, true) then
            installedFlat[id] = true
          end
        end
      end
      markInstalled()
      render()
    end
  )

  noctalia.runAsync("nix profile list --json", function(res)
    installedNix = {}
    if res.exitCode == 0 then
      local ok, data = pcall(noctalia.json.decode, res.stdout or "")
      if ok and type(data) == "table" and type(data.elements) == "table" then
        for name in pairs(data.elements) do
          if name ~= "home-manager-path" then
            installedNix[name] = true
          end
        end
      end
    end
    markInstalled()
    render()
  end, 60000)
end

local function flatSearch(q)
  flSearching = true
  flError = nil
  render()
  noctalia.runAsync("flatpak search --columns=application,name,description " .. shq(q), function(res)
    flSearching = false
    local items = {}
    if res.exitCode == 0 then
      for _, line in splitLines(res.stdout) do
        local id, name, desc = line:match("^([%w_.%-]+)\t([^\t]+)\t?(.*)$")
        if id and id:find(".", 1, true) then
          table.insert(items, {
            key = "fl:" .. id,
            kind = "flatpak",
            id = id,
            name = name,
            desc = trim(desc),
            installed = installedFlat[id] == true,
          })
        end
      end
    end
    flResults = items
    if #items == 0 then
      flError = "Nada encontrado para '" .. q .. "' no Flathub."
    end
    resetSelection()
    render()
  end, 60000)
end

local function nixSearch(q)
  nxSearching = true
  nxError = nil
  render()
  noctalia.runAsync("nix search nixpkgs " .. shq(q) .. " --json", function(res)
    nxSearching = false
    if res.exitCode ~= 0 then
      nxResults = {}
      nxError = "nix search falhou: " .. trim(res.stderr):sub(1, 300)
      render()
      return
    end
    local ok, data = pcall(noctalia.json.decode, res.stdout or "")
    if not ok or type(data) ~= "table" then
      nxResults = {}
      nxError = "JSON inválido do nix search"
      render()
      return
    end
    local items = {}
    local needle = q:lower()
    for key, info in pairs(data) do
      if type(info) == "table" then
        local attr = key:match("^legacyPackages%.[^%.]+%.(.+)$") or key
        local pname = info.pname or attr
        table.insert(items, {
          key = "nx:" .. attr,
          kind = "nix",
          attr = attr,
          name = pname,
          version = info.version or "",
          desc = info.description or "",
          installed = installedNix[pname] == true,
        })
      end
    end
    local function score(a)
      local n = a.name:lower()
      if n == needle then return 0 end
      if n:find(needle, 1, true) == 1 then return 1 end
      if a.attr:lower():find(needle, 1, true) then return 2 end
      return 3
    end
    table.sort(items, function(a, b)
      local sa, sb = score(a), score(b)
      if sa ~= sb then return sa < sb end
      return a.name < b.name
    end)
    while #items > 40 do
      table.remove(items)
    end
    nxResults = items
    if #items == 0 then
      nxError = "Nada encontrado para '" .. q .. "' no nixpkgs."
    end
    resetSelection()
    render()
  end, 60000)
end

local function flatInstall(id)
  if runInTerminal("sudo flatpak install --system --noninteractive flathub " .. shq(id)) then
    actionStatus = "Instalação de " .. id .. " no terminal."
    render()
  end
end

local function nixInstall(attr)
  if runInTerminal("nix profile install " .. shq("nixpkgs#" .. attr)) then
    actionStatus = "Instalando " .. attr .. " no terminal."
    render()
  end
end

-- ── web apps ────────────────────────────────────────────────────────────────

local waName = ""
local waUrl = ""
local waCreating = false
local waStatus = nil

local function normalizeUrl(u)
  u = trim(u)
  if u ~= "" and not u:match("^%a[%w%+%.%-]*:") then
    u = "https://" .. u
  end
  return u
end

local function safeIconName(s)
  s = (s:lower():gsub("[^%w]+", "-"))
  s = (s:gsub("^-+", ""))
  s = (s:gsub("-+$", ""))
  if s == "" then s = "webapp" end
  return s
end

local function desktopEscape(s)
  s = s:gsub("\\", "\\\\")
  s = s:gsub("\n", "\\n")
  s = s:gsub("\r", "\\r")
  s = s:gsub("\t", "\\t")
  return s
end

local function tryDownloadSeq(urls, dest, cb, idx)
  idx = idx or 1
  local url = urls[idx]
  if url == nil then
    cb(false)
    return
  end
  noctalia.download(url, dest, function(ok)
    if ok then
      cb(true)
    else
      tryDownloadSeq(urls, dest, cb, idx + 1)
    end
  end)
end

local function fetchSiteIcon(siteUrl, dest, cb)
  local domain = siteUrl:match("^https?://([^/:?#]+)")
  if domain == nil then
    cb(false)
    return
  end
  local origin = siteUrl:match("^(https?://[^/]+)") or ("https://" .. domain)
  local apple = nil
  noctalia.http({ url = siteUrl, headers = { "User-Agent: Mozilla/5.0" } }, function(res)
    local body = res.body or res.text or res.data
    if res.ok and type(body) == "string" then
      local tag = body:match('<link[^>]-rel=["\'][^"\']-apple%-touch%-icon[^"\']-["\'][^>]->')
      local href = tag and tag:match('href%s*=%s*["\']([^"\']+)["\']')
      if href == nil then
        for tag2 in body:gmatch("<link[^>]->") do
          if tag2:find("apple%-touch%-icon") then
            href = tag2:match('href%s*=%s*["\']([^"\']+)["\']')
            if href then break end
          end
        end
      end
      if href then
        if href:match("^//") then
          apple = "https:" .. href
        elseif href:match("^/") then
          apple = origin .. href
        elseif not href:match("^https?://") then
          apple = origin .. "/" .. href
        else
          apple = href
        end
      end
    end
    local urls = {}
    if apple then
      table.insert(urls, apple)
    end
    table.insert(urls, origin .. "/apple-touch-icon.png")
    table.insert(urls, "https://www.google.com/s2/favicons?domain=" .. noctalia.string.urlEncode(domain) .. "&sz=256")
    tryDownloadSeq(urls, dest, cb)
  end)
end

local function loadWebApps()
  webApps = {}
  local dir = desktopDir()
  local entries = noctalia.listDir(dir)
  if type(entries) == "table" then
    table.sort(entries)
    for _, fname in ipairs(entries) do
      if fname:match("%.desktop$") then
        local content = noctalia.readFile(dir .. "/" .. fname)
        if type(content) == "string" then
          local url = content:match("%-%-app=(%S+)")
          if url then
            table.insert(webApps, {
              key = "web:" .. fname,
              kind = "web",
              file = fname,
              name = content:match("\nName=([^\r\n]+)") or fname,
              icon = content:match("\nIcon=([^\r\n]+)") or "",
              url = url,
            })
          end
        end
      end
    end
  end
  webAppsLoaded = true
end

local function removeWebApp(app)
  noctalia.removeFile(desktopDir() .. "/" .. app.file)
  local icon = app.icon
  if icon ~= "" and not icon:find("/", 1, true) then
    for _, ext in ipairs({ ".png", ".svg" }) do
      local ipath = iconDir() .. "/" .. icon .. ext
      if noctalia.fileExists(ipath) then
        noctalia.removeFile(ipath)
      end
    end
  end
  notify("Web app '" .. app.name .. "' removido.")
  actionStatus = "Web app '" .. app.name .. "' removido."
  if selected ~= nil and selected.key == app.key then
    resetSelection()
  end
  loadWebApps()
  render()
end

local function createWebApp()
  local name = trim(waName)
  local url = normalizeUrl(waUrl)

  if name == "" or url == "" then
    notifyError("Informe nome e URL do web app.")
    return
  end
  if name:find("/", 1, true) then
    notifyError("O nome não pode conter '/'.")
    return
  end
  if not url:lower():match("^https?://") then
    notifyError("A URL precisa ser http(s): " .. url)
    return
  end
  if url:find("%s") then
    notifyError("A URL não pode conter espaços.")
    return
  end

  waCreating = true
  waStatus = "Buscando ícone do site..."
  render()

  local iconValue = safeIconName(name)
  local dest = iconDir() .. "/" .. iconValue .. ".png"
  noctalia.mkdirAll(iconDir())

  fetchSiteIcon(url, dest, function(ok)
    if not ok then
      iconValue = "text-html"
      waStatus = "Sem ícone; usando ícone genérico."
    else
      waStatus = "Criando lançador..."
    end
    render()

    local desktopFile = desktopDir() .. "/" .. name .. ".desktop"
    local content = table.concat({
      "[Desktop Entry]",
      "Version=1.0",
      "Name=" .. desktopEscape(name),
      "Comment=" .. desktopEscape(name),
      "Exec=" .. desktopEscape(browserExec .. " --app=" .. url),
      "Terminal=false",
      "Type=Application",
      "Icon=" .. desktopEscape(iconValue),
      "StartupNotify=true",
      "Categories=Network;",
      "",
    }, "\n")

    noctalia.mkdirAll(desktopDir())
    noctalia.writeFile(desktopFile, content)

    local check = noctalia.readFile(desktopFile)
    waCreating = false
    if type(check) ~= "string" or not check:find("Name=" .. desktopEscape(name), 1, true) then
      waStatus = nil
      notifyError("Não consegui escrever " .. desktopFile)
    else
      waStatus = "Criado! Disponível no launcher."
      notify("Web app '" .. name .. "' criado no launcher.")
      waName = ""
      waUrl = ""
      loadWebApps()
    end
    render()
  end)
end

-- ── Instalar ────────────────────────────────────────────────────────────────

local function setInstTab(id)
  instTab = id
  resetSelection()
  actionStatus = nil
  render()
end

local function installAction()
  if selected == nil then
    return nil
  end
  if selected.kind == "flatpak" then
    if selected.installed then
      return { label = "Já está instalado", glyph = "check", enabled = false, onClick = "onInstGo" }
    end
    return { label = "Instalar (Flatpak)", glyph = "download", onClick = "onInstGo" }
  end
  if selected.kind == "nix" then
    if selected.installed then
      return { label = "Já está instalado", glyph = "check", enabled = false, onClick = "onInstGo" }
    end
    return { label = "Instalar (nix profile)", glyph = "download", onClick = "onInstGo" }
  end
  return nil
end

function onInstGo()
  if selected == nil then
    return
  end
  if selected.kind == "flatpak" then
    flatInstall(selected.id)
  elseif selected.kind == "nix" then
    nixInstall(selected.attr)
  end
end

local function searchBox(key, value, placeholder, onChange, onSubmit, onSearch, busy)
  return ui.row({ align = "center", gap = 8 }, {
    ui.input({
      key = key,
      value = value,
      placeholder = placeholder,
      flexGrow = 1,
      onChange = onChange,
      onSubmit = onSubmit,
    }),
    ui.button({
      text = "Buscar",
      glyph = "search",
      variant = "primary",
      enabled = not busy and trim(value) ~= "",
      onClick = onSearch,
    }),
  })
end

local function listOrMessage(rows, loading, err, empty)
  if loading then
    return { ui.label({ text = "Buscando...", color = "on_surface_variant" }) }
  end
  if err ~= nil then
    return { ui.label({ text = err, color = "error", maxLines = 4 }) }
  end
  if #rows == 0 then
    return { ui.label({ text = empty, color = "on_surface_variant", fontSize = 12 }) }
  end
  return rows
end

local function renderInstall()
  local children = { header("Instalar", {}) }

  table.insert(children, tabsBar({
    { id = "flatpak", label = "Flatpak", glyph = "box" },
    { id = "nix", label = "Nix", glyph = "package" },
    { id = "web", label = "Web app", glyph = "app-window" },
  }, instTab, setInstTab))

  if instTab == "flatpak" then
    table.insert(children, searchBox(
      "inst-search-flatpak",
      flQuery,
      "Buscar app no Flathub (ex.: vlc)...",
      function(v) flQuery = v or "" end,
      "onFlSubmit",
      "onFlSearch",
      flSearching
    ))

    local rows = {}
    if flResults ~= nil then
      for _, item in ipairs(flResults) do
        table.insert(rows, itemRow(item))
      end
    end
    table.insert(children, splitPane(
      listOrMessage(rows, flSearching, flError, "Busque um app pelo nome para ver os resultados."),
      selectionPane({
        action = installAction(),
        status = actionStatus,
        empty = "Passe o mouse num resultado para ver o preview do Flathub aqui.",
      })
    ))
    table.insert(children, hint("O preview mostra os detalhes do app (flatpak remote-info); clicar em Instalar abre o terminal para a senha."))
  elseif instTab == "nix" then
    table.insert(children, searchBox(
      "inst-search-nix",
      nxQuery,
      "Buscar pacote no nixpkgs (ex.: ripgrep)...",
      function(v) nxQuery = v or "" end,
      "onNxSubmit",
      "onNxSearch",
      nxSearching
    ))

    local rows = {}
    if nxResults ~= nil then
      for _, item in ipairs(nxResults) do
        table.insert(rows, itemRow(item))
      end
    end
    table.insert(children, splitPane(
      listOrMessage(rows, nxSearching, nxError, "Busque um pacote do nixpkgs para ver os resultados."),
      selectionPane({
        action = installAction(),
        status = actionStatus,
        empty = "Passe o mouse num pacote para ver descrição, versão e attr aqui.",
      })
    ))
    table.insert(children, hint("Instala com `nix profile install nixpkgs#...` (sem sudo); a remoção fica em Remover › Nix."))
  else
    table.insert(children, ui.input({
      key = "wa-name",
      value = waName,
      placeholder = "Nome do web app (ex.: YouTube)",
      onChange = function(v) waName = v or "" end,
    }))
    table.insert(children, ui.input({
      key = "wa-url",
      value = waUrl,
      placeholder = "URL (ex.: youtube.com)",
      onChange = function(v) waUrl = v or "" end,
      onSubmit = "onWaUrlSubmit",
    }))
    table.insert(children, ui.row({ align = "center", gap = 8 }, {
      ui.button({
        text = "Criar web app",
        glyph = "app-window",
        variant = "primary",
        enabled = not waCreating,
        onClick = "onCreateWebApp",
      }),
      ui.label({ text = browserExec .. " --app", fontSize = 10, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
    }))
    table.insert(children, statusLine(waStatus))
    table.insert(children, ui.spacer({ flexGrow = 1 }))
    table.insert(children, hint("Cria um .desktop em ~/.local/share/applications com o ícone do site; some em Remover › Web apps."))
  end

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── Remover ─────────────────────────────────────────────────────────────────

local function loadFlatApps()
  flatLoading = true
  render()
  local cmd = "flatpak list --system --app --columns=application,name,version 2>/dev/null"
    .. "; printf '\\n--user--\\n'; flatpak list --user --app --columns=application,name,version 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    flatLoading = false
    local items = {}
    local scope = "system"
    for _, line in splitLines(res.stdout or "") do
      if line == "--user--" then
        scope = "user"
      else
        local id, name, ver = line:match("^([%w_.%-]+)\t([^\t]+)\t?([^\t]*)$")
        if id and id:find(".", 1, true) then
          table.insert(items, {
            key = "ifl:" .. scope .. ":" .. id,
            kind = "flatpakInstalled",
            id = id,
            name = name,
            version = trim(ver),
            scope = scope,
          })
        end
      end
    end
    table.sort(items, function(a, b)
      return a.name < b.name
    end)
    flatApps = items
    if selected ~= nil and selected.kind == "flatpakInstalled" then
      resetSelection()
    end
    render()
  end, 60000)
end

local function loadNixProfile()
  nixLoading = true
  render()
  noctalia.runAsync("nix profile list --json", function(res)
    nixLoading = false
    local items = {}
    removeError = nil
    if res.exitCode == 0 then
      local ok, data = pcall(noctalia.json.decode, res.stdout or "")
      if ok and type(data) == "table" and type(data.elements) == "table" then
        for name, info in pairs(data.elements) do
          if name ~= "home-manager-path" then
            info = type(info) == "table" and info or {}
            local store = (type(info.storePaths) == "table" and info.storePaths[1]) or ""
            local base = store:match("/([^/]+)$") or ""
            table.insert(items, {
              key = "inx:" .. name,
              kind = "nixInstalled",
              name = name,
              version = base:match("-(%d[%w%.%_%+]*)$") or "",
              attr = info.attrPath or "",
              store = store,
              origin = info.originalUrl or "",
            })
          end
        end
      end
    else
      removeError = "nix profile list falhou: " .. trim(res.stderr):sub(1, 200)
    end
    table.sort(items, function(a, b)
      return a.name < b.name
    end)
    nixApps = items
    if selected ~= nil and selected.kind == "nixInstalled" then
      resetSelection()
    end
    render()
  end, 60000)
end

local function flatRemove(app)
  if app.scope == "system" then
    if runInTerminal("sudo flatpak uninstall --system --noninteractive " .. shq(app.id)) then
      actionStatus = "Remoção de " .. app.id .. " no terminal."
      render()
    end
  else
    actionStatus = "Removendo " .. app.id .. "..."
    render()
    noctalia.runAsync("flatpak uninstall --user --noninteractive " .. shq(app.id), function(res)
      if res.exitCode == 0 then
        actionStatus = app.id .. " removido."
        notify(app.id .. " removido.")
      else
        actionStatus = "Falha: " .. trim(res.stderr):sub(1, 200)
        notifyError("Falha ao remover " .. app.id .. ": " .. trim(res.stderr))
      end
      resetSelection()
      loadFlatApps()
    end, 60000)
  end
end

local function nixRemove(item)
  actionStatus = "Removendo " .. item.name .. " do profile..."
  render()
  noctalia.runAsync("nix profile remove " .. shq(item.name), function(res)
    if res.exitCode == 0 then
      actionStatus = item.name .. " removido do nix profile."
      notify(item.name .. " removido do nix profile.")
    else
      actionStatus = "Falha: " .. trim(res.stderr):sub(1, 200)
      notifyError("Falha ao remover " .. item.name .. ": " .. trim(res.stderr))
    end
    resetSelection()
    loadNixProfile()
  end, 60000)
end

local function removeAction()
  if selected == nil then
    return nil
  end
  if selected.kind == "flatpakInstalled" then
    return { label = "Remover (Flatpak)", glyph = "trash", variant = "destructive", onClick = "onRmGo" }
  end
  if selected.kind == "nixInstalled" then
    return { label = "Remover (nix profile)", glyph = "trash", variant = "destructive", onClick = "onRmGo" }
  end
  if selected.kind == "web" then
    return { label = "Remover web app", glyph = "trash", variant = "destructive", onClick = "onRmGo" }
  end
  return nil
end

function onRmGo()
  if selected == nil then
    return
  end
  if selected.kind == "flatpakInstalled" then
    flatRemove(selected)
  elseif selected.kind == "nixInstalled" then
    nixRemove(selected)
  elseif selected.kind == "web" then
    removeWebApp(selected)
  end
end

local function setRemoveTab(id)
  removeTab = id
  removeError = nil
  resetSelection()
  actionStatus = nil
  render()
end

local function renderRemove()
  local children = { header("Remover", {}) }

  table.insert(children, tabsBar({
    { id = "flatpak", label = "Flatpak", glyph = "box" },
    { id = "nix", label = "Nix", glyph = "package" },
    { id = "web", label = "Web apps", glyph = "app-window" },
  }, removeTab, setRemoveTab))

  local rows = {}
  local loading = false
  local empty = "Nada aqui."
  local err = nil
  local refreshName = "onRmReload"

  if removeTab == "flatpak" then
    loading = flatLoading
    err = removeError
    empty = "Nenhum Flatpak instalado (system + user)."
    if flatApps == nil then
      loading = true
    else
      for _, item in ipairs(flatApps) do
        table.insert(rows, itemRow(item))
      end
    end
  elseif removeTab == "nix" then
    loading = nixLoading
    err = removeError
    empty = "Nenhum pacote no nix profile."
    if nixApps == nil then
      loading = true
    else
      for _, item in ipairs(nixApps) do
        table.insert(rows, itemRow(item))
      end
    end
  else
    if not webAppsLoaded then
      loadWebApps()
    end
    for _, item in ipairs(webApps) do
      table.insert(rows, itemRow(item))
    end
    empty = "Nenhum web app criado pelo Hamra Control."
    refreshName = "onWebReload"
  end

  table.insert(children, ui.row({ align = "center", gap = 8 }, {
    ui.button({ text = "Recarregar lista", glyph = "reload", variant = "ghost", onClick = refreshName, enabled = not loading }),
    ui.label({
      text = loading and "Carregando..." or "",
      color = "on_surface_variant",
      fontSize = 11,
      flexGrow = 1,
    }),
  }))

  table.insert(children, splitPane(
    listOrMessage(rows, loading, err, empty),
    selectionPane({
      action = removeAction(),
      status = actionStatus,
      empty = "Passe o mouse num item para ver os detalhes aqui.",
    })
  ))

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── Atualizar ───────────────────────────────────────────────────────────────

local function renderUpdate()
  local children = { header("Atualizar", {}) }

  table.insert(children, ui.label({
    text = "Host: " .. host .. "  ·  " .. repo,
    fontSize = 12,
    color = "on_surface_variant",
  }))

  table.insert(children, ui.column({ gap = 8 }, {
    ui.button({
      text = "nix flake update + rebuild",
      glyph = "refresh",
      variant = "primary",
      onClick = "onUpdateAll",
    }),
    ui.button({ text = "Rebuild (switch)", glyph = "player-play", onClick = "onRebuildSwitch2" }),
    ui.button({ text = "Rebuild (boot, aplica no próximo boot)", glyph = "device-floppy", onClick = "onRebuildBoot" }),
  }))

  table.insert(children, hint("O rebuild roda num terminal porque o sudo pede sua senha. O flake update também atualiza o lock do Home Manager."))
  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── Sistema ─────────────────────────────────────────────────────────────────

local sysInfo = nil
local sysLoading = false
local rollbackArmed = false

local function loadSystemInfo()
  sysLoading = true
  render()
  local cmd = "readlink -f /run/current-system 2>/dev/null; echo ---; nixos-version 2>/dev/null; echo ---; uname -r; echo ---; uptime -p 2>/dev/null"
  noctalia.runAsync(cmd, function(res)
    sysLoading = false
    local parts = {}
    local idx = 1
    for _, line in splitLines(res.stdout or "") do
      if line == "---" then
        idx += 1
      else
        parts[idx] = (parts[idx] ~= nil and (parts[idx] .. "\n" .. line)) or line
      end
    end
    sysInfo = {
      generation = parts[1] or "?",
      nixosVersion = parts[2] or "?",
      kernel = parts[3] or "?",
      uptime = parts[4] or "?",
    }
    render()
  end, 60000)
end

local function infoRow(label, value)
  return ui.row({ align = "center", gap = 10 }, {
    ui.label({ text = label, width = 110, fontSize = 12, color = "on_surface_variant" }),
    ui.label({ text = value, fontSize = 12, flexGrow = 1, maxLines = 2 }),
  })
end

local function renderSystem()
  local children = { header("Sistema", {}) }

  local infoBlock = {}
  if sysLoading then
    table.insert(infoBlock, ui.label({ text = "Coletando info...", color = "on_surface_variant" }))
  elseif sysInfo ~= nil then
    table.insert(infoBlock, infoRow("Kernel", sysInfo.kernel))
    table.insert(infoBlock, infoRow("NixOS", sysInfo.nixosVersion))
    table.insert(infoBlock, infoRow("Uptime", sysInfo.uptime))
    table.insert(infoBlock, infoRow("Geração", sysInfo.generation))
  else
    table.insert(infoBlock, ui.button({ text = "Carregar info", glyph = "reload", onClick = "onSysReload" }))
  end
  table.insert(children, ui.column({ gap = 6 }, infoBlock))

  table.insert(children, ui.separator({ spacing = 6 }))

  table.insert(children, ui.column({ gap = 8 }, {
    ui.button({ text = "Listar gerações", glyph = "list-search", onClick = "onSysGenerations" }),
    ui.button({ text = "Coletar lixo (nix-collect-garbage -d)", glyph = "trash", onClick = "onSysGc" }),
    ui.button({ text = "Editar configuration.nix", glyph = "edit", onClick = "onSysEditConfig" }),
    ui.button({
      text = rollbackArmed and "Confirmar rollback?" or "Rollback para geração anterior",
      glyph = "restore",
      variant = rollbackArmed and "primary" or "outline",
      onClick = "onSysRollback",
    }),
  }))

  table.insert(children, hint("Rollback troca o sistema em execução para a geração anterior do perfil system."))
  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── Home (menu em grade) ────────────────────────────────────────────────────

local hoveredCard = nil

local function menuCard(entry)
  local hovered = hoveredCard == entry.id
  return ui.column({
    key = "card-" .. entry.id,
    flexGrow = 1,
    height = 104,
    gap = 6,
    padding = 14,
    paddingV = 12,
    align = "start",
    fill = hovered and "primary/0.12" or "surface",
    radius = 12,
    border = "outline",
    borderWidth = 1,
    onHover = function(state)
      local id = (state == "true") and entry.id or nil
      if hoveredCard ~= id then
        hoveredCard = id
        render()
      end
    end,
    onClick = function()
      openView(entry.id)
    end,
  }, {
    ui.glyph({ name = entry.glyph, size = 22, color = "primary" }),
    ui.label({ text = entry.label, fontSize = 15, fontWeight = "bold", maxLines = 1 }),
    ui.label({ text = entry.sub, fontSize = 10, color = "on_surface_variant", maxLines = 2 }),
  })
end

local function renderHome()
  local rows = {}
  for i = 1, #MENU, 3 do
    local row = {}
    for j = i, math.min(i + 2, #MENU) do
      table.insert(row, menuCard(MENU[j]))
    end
    table.insert(rows, ui.row({ gap = 10, align = "stretch" }, row))
  end

  local footer = {}
  local n = pendingCount()
  if n > 0 then
    table.insert(footer, ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "alert-triangle", size = 16, color = "warning" }),
      ui.label({
        text = n == 1 and "1 toggle pendente de aplicar" or (n .. " toggles pendentes de aplicar"),
        fontSize = 12,
        flexGrow = 1,
      }),
      ui.button({ text = "Rebuild (" .. n .. ")", glyph = "refresh", variant = "primary", onClick = "onRebuildSwitch" }),
    }))
  end

  return ui.column({ flexGrow = 1, gap = 14, align = "stretch" }, {
    ui.row({ align = "center", gap = 8 }, {
      ui.glyph({ name = "settings", size = 18, color = "primary" }),
      ui.label({ text = "Hamra Control", fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
      ui.button({ glyph = "close", variant = "ghost", tooltip = "Fechar", onClick = function() panel.close() end }),
    }),
    ui.label({ text = "Host: " .. host .. "  ·  " .. repo, fontSize = 11, color = "on_surface_variant" }),
    ui.spacer({ flexGrow = 1 }),
    ui.column({ gap = 10, align = "stretch" }, rows),
    ui.spacer({ flexGrow = 1 }),
    ui.column({ gap = 8 }, footer),
    hint("Atalho: Alt+Space · ou digite /hamra no launcher."),
  })
end

-- ── render / navegação ──────────────────────────────────────────────────────

render = function()
  local content
  if view == "apps" then
    content = renderApps()
  elseif view == "keys" then
    content = renderKeys()
  elseif view == "install" then
    content = renderInstall()
  elseif view == "remove" then
    content = renderRemove()
  elseif view == "update" then
    content = renderUpdate()
  elseif view == "system" then
    content = renderSystem()
  else
    content = renderHome()
  end
  panel.render(content)
end

openView = function(id)
  view = id
  rollbackArmed = false
  hoveredCard = nil
  actionStatus = nil
  if id == "apps" and not appsLoaded and not appsLoading then
    loadApps()
  elseif id == "system" and sysInfo == nil and not sysLoading then
    loadSystemInfo()
  elseif id == "keys" then
    loadSshPubs()
  elseif id == "install" then
    loadInstalledSets()
  elseif id == "remove" then
    if flatApps == nil and not flatLoading then
      loadFlatApps()
    end
    if nixApps == nil and not nixLoading then
      loadNixProfile()
    end
    if not webAppsLoaded then
      loadWebApps()
    end
  end
  render()
end

-- ── callbacks (globals chamados pelo host) ──────────────────────────────────

function onBack()
  view = "home"
  rollbackArmed = false
  hoveredCard = nil
  render()
end

function onAppsReload()
  loadApps()
end

function onSshGenerate()
  sshGenerate()
end

function onSshCopyDefault()
  if #sshPubs == 0 then
    notifyError("Nenhuma chave pública em ~/.ssh.")
    return
  end
  local chosen = nil
  for _, name in ipairs(sshPubs) do
    if name == "id_ed25519.pub" then
      chosen = name
      break
    end
  end
  copySshPub(chosen or sshPubs[1])
end

function onSshAgent()
  runInTerminal("ssh-add " .. shq(home .. "/.ssh/id_ed25519") .. " 2>/dev/null || ssh-add")
end

function onSshEditConfig()
  runInTerminal("mkdir -p ~/.ssh && touch ~/.ssh/config && " .. editorExec .. " ~/.ssh/config")
end

function onGpgGenerate()
  runInTerminal("gpg --full-generate-key")
end

function onGpgList()
  gpgBusy = true
  render()
  noctalia.runAsync("gpg --list-secret-keys --keyid-format LONG", function(res)
    gpgBusy = false
    gpgListText = trim(res.stdout or "")
    if gpgListText == "" then
      gpgListText = "Nenhuma chave secreta encontrada."
    end
    render()
  end)
end

function onGpgGitSign()
  setGitSigning()
end

function onGpgEditAgent()
  runInTerminal("mkdir -p ~/.gnupg && chmod 700 ~/.gnupg && touch ~/.gnupg/gpg-agent.conf && " .. editorExec .. " ~/.gnupg/gpg-agent.conf")
end

function onFlSearch()
  if trim(flQuery) ~= "" then
    flatSearch(flQuery)
  end
end

function onFlSubmit(value)
  flQuery = trim(value or flQuery)
  if flQuery ~= "" then
    flatSearch(flQuery)
  end
end

function onNxSearch()
  if trim(nxQuery) ~= "" then
    nixSearch(nxQuery)
  end
end

function onNxSubmit(value)
  nxQuery = trim(value or nxQuery)
  if nxQuery ~= "" then
    nixSearch(nxQuery)
  end
end

function onWaUrlSubmit(value)
  waUrl = value or waUrl
  createWebApp()
end

function onCreateWebApp()
  createWebApp()
end

function onWebReload()
  loadWebApps()
  render()
end

function onRmReload()
  if removeTab == "flatpak" then
    loadFlatApps()
  elseif removeTab == "nix" then
    loadNixProfile()
  else
    loadWebApps()
    render()
  end
end

function onUpdateAll()
  local cmd = "cd " .. shq(repo)
    .. " && nix flake update && sudo nixos-rebuild switch --flake " .. shq(repo .. "#" .. host)
  if runInTerminal(cmd) then
    notify("flake update + rebuild disparados no terminal.")
  end
end

function onRebuildSwitch2()
  runRebuild("switch")
end

function onRebuildBoot()
  runRebuild("boot")
end

function onSysReload()
  loadSystemInfo()
end

function onSysGenerations()
  runInTerminal("sudo nixos-rebuild list-generations")
end

function onSysGc()
  runInTerminal("sudo nix-collect-garbage -d")
end

function onSysEditConfig()
  runInTerminal(editorExec .. " " .. shq(repo .. "/hosts/" .. host .. "/configuration.nix"))
end

function onSysRollback()
  if not rollbackArmed then
    rollbackArmed = true
    render()
    return
  end
  rollbackArmed = false
  runInTerminal("sudo /run/current-system/bin/switch-to-configuration rollback")
  render()
end

-- Controle externo via `noctalia msg plugin gabrielnathan929/hamra-control:main all <evento> [payload]`:
--   view   <id>        abre uma view (home, apps, install, remove, update, keys, system)
--   tab    <view>:<tab> troca a aba (install:flatpak | install:nix | install:web | remove:...)
--   search <origem> <q> busca e mostra o preview (flatpak | nix)
--   select <key>       seleciona um item para o preview (fl:, nx:, ifl:, inx:, web:)
function onIpc(event, payload)
  local e = trim(event or "")
  local p = trim(payload or "")

  if e == "view" then
    if p == "" or p == "home" then
      view = "home"
      render()
    else
      openView(p)
    end
    return
  end

  if e == "tab" then
    local v, t = p:match("^([%w]+):([%w%-_]+)$")
    if v ~= nil then
      if v == "install" then
        setInstTab(t)
      elseif v == "remove" then
        setRemoveTab(t)
      end
      if view ~= v then
        openView(v)
      end
    end
    return
  end

  if e == "search" then
    local origin, q = p:match("^(%w+)%s+(.+)$")
    if origin == "flatpak" then
      flQuery = q
      instTab = "flatpak"
      openView("install")
      flatSearch(q)
    elseif origin == "nix" then
      nxQuery = q
      instTab = "nix"
      openView("install")
      nixSearch(q)
    end
    return
  end

  if e == "select" then
    selectByKey(p)
    return
  end
end

function onOpen(_)
  local v = noctalia.state.get("hamra_view")
  if type(v) == "string" and v ~= "" then
    noctalia.state.set("hamra_view", "")
    openView(v)
    return
  end
  local q = noctalia.state.get("hamra_install_query")
  if type(q) == "string" and q ~= "" then
    noctalia.state.set("hamra_install_query", "")
    local tab = noctalia.state.get("hamra_install_tab")
    noctalia.state.set("hamra_install_tab", "")
    instTab = (type(tab) == "string" and tab == "nix") and "nix" or "flatpak"
    resetSelection()
    if instTab == "nix" then
      nxQuery = q
      openView("install")
      nixSearch(q)
    else
      flQuery = q
      openView("install")
      flatSearch(q)
    end
    return
  end
  if view ~= "home" then
    openView(view)
    return
  end
  render()
end

render()
