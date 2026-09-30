--!nonstrict

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

local view = "home"

local MENU = {
  { id = "apps", label = "Aplicativos", glyph = "app-window", sub = "Toggles hamra.programs" },
  { id = "install", label = "Instalar", glyph = "download", sub = "Flathub e web apps" },
  { id = "remove", label = "Remover", glyph = "trash", sub = "Flatpaks e web apps" },
  { id = "update", label = "Atualizar", glyph = "refresh", sub = "flake update e rebuild" },
  { id = "keys", label = "Chaves", glyph = "key", sub = "SSH e GPG" },
  { id = "system", label = "Sistema", glyph = "settings", sub = "Info, GC, gerações, rollback" },
}

local function runInTerminal(cmd)
  if not noctalia.runInTerminal(cmd) then
    notifyError("Não consegui abrir um terminal.")
    return false
  end
  return true
end

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
  end)
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
      table.insert(children, ui.scroll({ flexGrow = 1, gap = 14 }, sections))
    end
  end

  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

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
  noctalia.copyToClipboard(trim(content))
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

  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

local flQuery = ""
local flResults = nil
local flSearching = false
local flError = nil

local function flatSearch(q)
  flSearching = true
  flError = nil
  render()
  noctalia.runAsync("flatpak search --columns=application,name,description " .. shq(q), function(res)
    flSearching = false
    if res.exitCode ~= 0 then
      flResults = {}
      flError = "flatpak search não achou nada para '" .. q .. "'."
      render()
      return
    end
    local items = {}
    for _, line in splitLines(res.stdout) do
      local id, name, desc = line:match("^([%w%.%-]+)\t([^\t]+)\t?(.*)$")
      if id and id:find("%.") then
        table.insert(items, { id = id, name = name, desc = trim(desc) })
      end
    end
    while #items > 25 do
      table.remove(items)
    end
    flResults = items
    if #items == 0 then
      flError = "Nada encontrado para '" .. q .. "'."
    end
    render()
  end)
end

local function flatInstall(id)
  if runInTerminal("sudo flatpak install --system --noninteractive flathub " .. shq(id)) then
    notify("Instalação de " .. id .. " disparada no terminal.")
  end
end

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
    end
    render()
  end)
end

local function renderInstall()
  local children = { header("Instalar", {}) }

  table.insert(children, ui.label({ text = "Flathub", fontSize = 14, fontWeight = "bold", color = "primary" }))
  table.insert(children, ui.row({ align = "center", gap = 8 }, {
    ui.input({
      value = flQuery,
      placeholder = "Buscar app no Flathub...",
      flexGrow = 1,
      onChange = function(v) flQuery = v or "" end,
      onSubmit = "onFlSubmit",
    }),
    ui.button({
      text = "Buscar",
      glyph = "search",
      variant = "primary",
      enabled = not flSearching and trim(flQuery) ~= "",
      onClick = "onFlSearch",
    }),
  }))

  local flBlock = {}
  if flSearching then
    table.insert(flBlock, ui.label({ text = "Buscando...", color = "on_surface_variant" }))
  elseif flError ~= nil then
    table.insert(flBlock, ui.label({ text = flError, color = "error" }))
  elseif flResults ~= nil then
    for i, item in ipairs(flResults) do
      table.insert(flBlock, ui.row({ align = "center", gap = 10, key = "fl-" .. item.id }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = item.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
          ui.label({ text = item.id .. (#item.desc > 0 and "  ·  " .. item.desc or ""), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
        }),
        ui.button({ text = "Instalar", glyph = "download", variant = "outline", onClick = function() flatInstall(item.id) end }),
      }))
      if i < #flResults then
        table.insert(flBlock, ui.separator({ spacing = 4 }))
      end
    end
  end
  if #flBlock > 0 then
    table.insert(children, ui.scroll({ flexGrow = 1, gap = 6 }, flBlock))
  end

  table.insert(children, ui.separator({ spacing = 6 }))
  table.insert(children, ui.label({ text = "Web app (" .. browserExec .. " --app)", fontSize = 14, fontWeight = "bold", color = "primary" }))
  table.insert(children, ui.input({ value = waName, placeholder = "Nome (ex.: YouTube)", onChange = function(v) waName = v or "" end }))
  table.insert(children, ui.input({
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
    ui.label({ text = waStatus or "", fontSize = 11, color = "on_surface_variant", flexGrow = 1, maxLines = 1 }),
  }))

  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

local webApps = {}
local webAppsLoaded = false

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
  loadWebApps()
  render()
end

local flatApps = nil
local flatLoading = false

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
        local id, name, ver = line:match("^([%w%.%-]+)\t([^\t]+)\t?([^\t]*)$")
        if id and id:find("%.") then
          table.insert(items, { id = id, name = name, version = trim(ver), scope = scope })
        end
      end
    end
    table.sort(items, function(a, b)
      return a.name < b.name
    end)
    flatApps = items
    render()
  end)
end

local function flatRemove(app)
  if app.scope == "system" then
    if runInTerminal("sudo flatpak uninstall --system --noninteractive " .. shq(app.id)) then
      notify("Remoção de " .. app.id .. " disparada no terminal.")
    end
  else
    noctalia.runAsync("flatpak uninstall --user --noninteractive " .. shq(app.id), function(res)
      if res.exitCode == 0 then
        notify(app.id .. " removido.")
      else
        notifyError("Falha ao remover " .. app.id .. ": " .. trim(res.stderr))
      end
      loadFlatApps()
    end)
  end
end

local function renderRemove()
  local children = { header("Remover", {}) }

  table.insert(children, ui.label({ text = "Flatpaks", fontSize = 14, fontWeight = "bold", color = "primary" }))
  table.insert(children, ui.row({ align = "center", gap = 8 }, {
    ui.button({ text = "Listar instalados", glyph = "reload", onClick = "onFlatReload", enabled = not flatLoading }),
    ui.label({ text = flatLoading and "Carregando..." or "", color = "on_surface_variant", fontSize = 11 }),
  }))

  local rows = {}
  if flatApps ~= nil then
    for _, app in ipairs(flatApps) do
      table.insert(rows, ui.row({ align = "center", gap = 10, key = "rm-" .. app.scope .. "-" .. app.id }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = app.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
          ui.label({ text = app.id .. (app.version ~= "" and "  ·  " .. app.version or ""), fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
        }),
        ui.label({ text = app.scope, fontSize = 10, color = "on_surface_variant" }),
        ui.button({ glyph = "trash", variant = "ghost", tooltip = "Remover", onClick = function() flatRemove(app) end }),
      }))
    end
  end
  table.insert(children, ui.scroll({ flexGrow = 1, gap = 6 }, rows))

  table.insert(children, ui.separator({ spacing = 6 }))
  table.insert(children, ui.label({ text = "Web apps", fontSize = 14, fontWeight = "bold", color = "primary" }))
  if not webAppsLoaded then
    loadWebApps()
  end
  if #webApps == 0 then
    table.insert(children, ui.label({ text = "Nenhum web app criado pelo Hamra Control.", fontSize = 11, color = "on_surface_variant" }))
  else
    for _, app in ipairs(webApps) do
      table.insert(children, ui.row({ align = "center", gap = 10, key = "wa-" .. app.file }, {
        ui.column({ gap = 2, flexGrow = 1 }, {
          ui.label({ text = app.name, fontWeight = "bold", fontSize = 13, maxLines = 1 }),
          ui.label({ text = app.url, fontSize = 10, color = "on_surface_variant", maxLines = 1 }),
        }),
        ui.button({ glyph = "trash", variant = "ghost", tooltip = "Remover", onClick = function() removeWebApp(app) end }),
      }))
    end
  end
  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

local function renderUpdate()
  local children = { header("Atualizar", {}) }

  table.insert(children, ui.label({
    text = "Host: " .. host .. "  ·  " .. repo,
    fontSize = 12,
    color = "on_surface_variant",
  }))

  table.insert(children, ui.column({ gap = 10 }, {
    ui.button({
      text = "nix flake update + rebuild",
      glyph = "refresh",
      variant = "primary",
      onClick = "onUpdateAll",
    }),
    ui.button({ text = "Rebuild (switch)", glyph = "player-play", onClick = "onRebuildSwitch2" }),
    ui.button({ text = "Rebuild (boot, aplica no próximo boot)", glyph = "device-floppy", onClick = "onRebuildBoot" }),
  }))

  table.insert(children, ui.label({
    text = "O rebuild roda num terminal porque o sudo pede sua senha. O flake update também atualiza o lock do Home Manager.",
    fontSize = 11,
    color = "on_surface_variant",
    maxLines = 4,
  }))
  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

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
  end)
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

  table.insert(children, ui.column({ gap = 10 }, {
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

  table.insert(children, ui.label({
    text = "Rollback troca o sistema em execução para a geração anterior do perfil system.",
    fontSize = 11,
    color = "on_surface_variant",
    maxLines = 3,
  }))
  table.insert(children, ui.spacer({ flexGrow = 1 }))

  return ui.column({ flexGrow = 1, gap = 12 }, children)
end

function render()
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
    local rows = {}
    for i = 1, #MENU, 2 do
      local pair = {}
      local left = MENU[i]
      local right = MENU[i + 1]
      table.insert(pair, ui.button({
        text = left.label,
        glyph = left.glyph,
        variant = "outline",
        width = 340,
        height = 52,
        tooltip = left.sub,
        onClick = function() openView(left.id) end,
      }))
      if right ~= nil then
        table.insert(pair, ui.button({
          text = right.label,
          glyph = right.glyph,
          variant = "outline",
          width = 340,
          height = 52,
          tooltip = right.sub,
          onClick = function() openView(right.id) end,
        }))
      end
      table.insert(rows, ui.row({ gap = 10, align = "center" }, pair))
    end
    content = ui.column({ flexGrow = 1, gap = 14 }, {
      ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "settings", size = 18, color = "primary" }),
        ui.label({ text = "Hamra Control", fontSize = 18, fontWeight = "bold", flexGrow = 1 }),
        ui.button({ glyph = "close", variant = "ghost", tooltip = "Fechar", onClick = function() panel.close() end }),
      }),
      ui.label({ text = "Host: " .. host .. "  ·  " .. repo, fontSize = 11, color = "on_surface_variant" }),
      ui.column({ gap = 10 }, rows),
      ui.spacer({ flexGrow = 1 }),
    })
  end
  panel.render(content)
end

function openView(id)
  view = id
  rollbackArmed = false
  if id == "apps" and not appsLoaded and not appsLoading then
    loadApps()
  elseif id == "system" and sysInfo == nil and not sysLoading then
    loadSystemInfo()
  elseif id == "keys" then
    loadSshPubs()
  elseif id == "remove" and flatApps == nil and not flatLoading then
    loadFlatApps()
    loadWebApps()
  end
  render()
end

function onBack()
  view = "home"
  rollbackArmed = false
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

function onWaUrlSubmit(value)
  waUrl = value or waUrl
  createWebApp()
end

function onCreateWebApp()
  createWebApp()
end

function onFlatReload()
  loadFlatApps()
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
    openView("install")
    flQuery = q
    flatSearch(q)
    return
  end
  if view ~= "home" then
    openView(view)
    return
  end
  render()
end

render()
