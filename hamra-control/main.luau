--!nonstrict

-- Hamra Control — painel de controle do Hamra (NixOS) dentro do Noctalia.
--
-- Home: menu em grade com as seis áreas do painel. Instalar e Remover cobrem
-- Flatpak, pacotes nix (nix profile), ferramentas mise e web apps, sempre com o
-- painel de
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
local rollbackArmed = false

local view = "home"

local MENU = {
  { id = "apps", label = "Aplicativos", glyph = "app-window", sub = "Toggles do hamra.programs" },
  { id = "install", label = "Instalar", glyph = "download", sub = "Flatpak, nix, mise e web apps" },
  { id = "remove", label = "Remover", glyph = "trash", sub = "Flatpak, nix, mise e web apps" },
  { id = "update", label = "Atualizar", glyph = "refresh", sub = "flake update, mise e rebuild" },
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
local sshImportName = "id_ed25519"
local sshImportText = ""
local sshImportNonce = 0
local sshImportBusy = false
local sshTestText = nil
local sshTestBusy = false
local gpgImportText = ""
local gpgImportNonce = 0
local gpgImportBusy = false
local gpgTestText = nil

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

local function sshTestKey()
  sshTestBusy = true
  render()
  noctalia.runAsync("ssh -T -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new git@github.com 2>&1; true", function(res)
    sshTestBusy = false
    local out = trim(res.stdout or "")
    if out == "" then
      out = "(sem saída — verifique a rede)"
    end
    sshTestText = "ssh -T git@github.com:\n" .. out
    render()
  end)
end

local function sshImport()
  local name = trim(sshImportName)
  if name == "" then
    name = "id_ed25519"
  end
  if not name:match("^[%w%.%_%-]+$") then
    notifyError("Nome de arquivo inválido (use letras, números, ponto, _ ou -).")
    return
  end
  local text = trim(sshImportText)
  if text == "" then
    notifyError("Cole a chave privada no campo abaixo.")
    return
  end
  if not text:find("PRIVATE KEY") then
    notifyError("O conteúdo não parece uma chave privada (falta o bloco PRIVATE KEY).")
    return
  end
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  local dest = home .. "/.ssh/" .. name
  if noctalia.fileExists(dest) then
    notifyError("Já existe " .. dest .. " — apague ou escolha outro nome.")
    return
  end
  sshImportBusy = true
  render()
  noctalia.runAsync("mkdir -p " .. shq(home .. "/.ssh") .. " && chmod 700 " .. shq(home .. "/.ssh"), function(res)
    if res.exitCode ~= 0 then
      sshImportBusy = false
      notifyError("Não consegui preparar ~/.ssh: " .. trim(res.stderr))
      render()
      return
    end
    noctalia.writeFile(dest, text)
    noctalia.runAsync(
      "chmod 600 " .. shq(dest)
        .. " && ssh-keygen -y -f " .. shq(dest) .. " > " .. shq(dest .. ".pub")
        .. " && chmod 644 " .. shq(dest .. ".pub"),
      function(res2)
        sshImportBusy = false
        if res2.exitCode ~= 0 then
          notifyError("Chave rejeitada (senha ou formato?): " .. trim(res2.stderr))
          render()
          return
        end
        sshImportText = ""
        sshImportNonce = sshImportNonce + 1
        loadSshPubs()
        notify(name .. " instalada (600) + .pub gerada. Adicionando ao agent e testando…")
        render()
        noctalia.runAsync("ssh-add " .. shq(dest) .. " 2>&1", function(res3)
          local addOut = trim((res3.stdout or "") .. "\n" .. (res3.stderr or ""))
          if res3.exitCode == 0 then
            sshTestText = "ssh-add " .. name .. ": ok\n" .. addOut
          else
            sshTestText = "ssh-add " .. name .. " falhou (chave com senha? rode ssh-add no terminal):\n" .. addOut
          end
          render()
          sshTestKey()
        end)
      end
    )
  end)
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

local function gpgTest()
  noctalia.runAsync("gpg --list-secret-keys --with-colons 2>/dev/null | awk -F: '$1==\"sec\"{print $5; exit}'", function(res)
    local keyId = trim(res.stdout or "")
    if keyId == "" then
      gpgTestText = "Nenhuma chave secreta para testar."
      render()
      return
    end
    noctalia.runAsync(
      "fpr=$(gpg --list-secret-keys --with-colons "
        .. shq(keyId)
        .. " 2>/dev/null | awk -F: '$1==\"fpr\"{print $10; exit}'); "
        .. "if [ -n \"$fpr\" ]; then echo \"$fpr:6:\" | gpg --batch --yes --import-ownertrust 2>/dev/null; fi; "
        .. "echo 'hamra-control test "
        .. os.date("!%Y-%m-%dT%H:%M:%SZ")
        .. "' | gpg --batch --yes --clearsign -u "
        .. shq(keyId)
        .. " 2>&1 | head -20",
      function(res2)
        local out = trim(res2.stdout or "")
        if res2.exitCode == 0 then
          gpgTestText = "Teste clearsign ok (chave " .. keyId .. "):\n" .. out
          notify("GPG funcionando: mensagem assinada com " .. keyId)
        else
          gpgTestText = "Teste clearsign falhou (chave " .. keyId .. "):\n" .. out
          notifyError("GPG importou mas o teste falhou — veja abaixo.")
        end
        render()
      end
    )
  end)
end

local function gpgImport()
  local text = trim(gpgImportText)
  if text == "" then
    notifyError("Cole o bloco ASCII-armored da chave GPG.")
    return
  end
  if not text:find("PGP PRIVATE KEY BLOCK") then
    notifyError("O conteúdo não parece uma chave privada GPG (falta PGP PRIVATE KEY BLOCK).")
    return
  end
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  gpgImportBusy = true
  render()
  local tmp = home .. "/.gnupg/hamra-import.asc"
  noctalia.runAsync("mkdir -p " .. shq(home .. "/.gnupg") .. " && chmod 700 " .. shq(home .. "/.gnupg"), function(res)
    if res.exitCode ~= 0 then
      gpgImportBusy = false
      notifyError("Não consegui preparar ~/.gnupg: " .. trim(res.stderr))
      render()
      return
    end
    noctalia.writeFile(tmp, text)
    noctalia.runAsync("gpg --batch --import " .. shq(tmp) .. " 2>&1; rm -f " .. shq(tmp), function(res2)
      gpgImportBusy = false
      local out = trim(res2.stdout or "")
      gpgImportText = ""
      gpgImportNonce = gpgImportNonce + 1
      if res2.exitCode ~= 0 then
        gpgTestText = "gpg --import falhou:\n" .. out
        notifyError("Importação GPG falhou — veja o resultado abaixo.")
        render()
        return
      end
      gpgTestText = "gpg --import ok:\n" .. out
      notify("Chave GPG importada. Listando e testando…")
      render()
      onGpgList()
      gpgTest()
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
  table.insert(sshBlock, ui.separator({ spacing = 4 }))
  table.insert(sshBlock, ui.label({ text = "Importar chave privada (colar)", fontSize = 12, fontWeight = "bold", color = "primary" }))
  table.insert(sshBlock, ui.input({
    key = "ssh-import-name",
    value = sshImportName,
    placeholder = "nome do arquivo (id_ed25519)",
    onChange = function(v) sshImportName = v or "" end,
  }))
  table.insert(sshBlock, ui.input({
    key = "ssh-import-text-" .. tostring(sshImportNonce),
    value = "",
    placeholder = "cole aqui -----BEGIN OPENSSH PRIVATE KEY----- …",
    multiline = true,
    height = 120,
    onChange = function(v) sshImportText = v or "" end,
  }))
  table.insert(sshBlock, ui.row({ align = "center", gap = 8 }, {
    ui.button({ text = "Importar privada", glyph = "download", onClick = "onSshImport", enabled = not sshImportBusy }),
    ui.button({ text = "Testar GitHub", glyph = "check", onClick = "onSshTest", enabled = not sshTestBusy }),
  }))
  if sshTestText ~= nil then
    table.insert(sshBlock, ui.label({ text = sshTestText, fontSize = 11, maxLines = 12, color = "on_surface_variant" }))
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
  table.insert(gpgBlock, ui.separator({ spacing = 4 }))
  table.insert(gpgBlock, ui.label({ text = "Importar chave privada (colar)", fontSize = 12, fontWeight = "bold", color = "primary" }))
  table.insert(gpgBlock, ui.input({
    key = "gpg-import-text-" .. tostring(gpgImportNonce),
    value = "",
    placeholder = "cole aqui -----BEGIN PGP PRIVATE KEY BLOCK----- …",
    multiline = true,
    height = 120,
    onChange = function(v) gpgImportText = v or "" end,
  }))
  table.insert(gpgBlock, ui.row({ align = "center", gap = 8 }, {
    ui.button({ text = "Importar privada", glyph = "download", onClick = "onGpgImport", enabled = not gpgImportBusy }),
    ui.button({ text = "Testar assinatura", glyph = "check", onClick = "onGpgTest" }),
  }))
  if gpgTestText ~= nil then
    table.insert(gpgBlock, ui.label({ text = gpgTestText, fontSize = 11, maxLines = 18, color = "on_surface_variant" }))
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

  if item.kind == "webnix" then
    preview = { text = table.concat({
      "Web app declarado no Nix",
      "",
      "URL: " .. (item.url or ""),
      "Declaração: hamra.webapps." .. (item.nixKey or ""),
      "Manifesto: /etc/hamra/apps.json",
      "",
      "Declarativo: para remover, desligue o toggle correspondente",
      "em Aplicativos (ex.: optionals.gui.notion) e faça rebuild.",
    }, "\n") }
    return
  end

  if item.kind == "updTask" or item.kind == "sysTask" then
    preview = { text = item.detail or item.name }
    return
  end

  if item.kind == "miseOutdated" then
    preview = { text = table.concat({
      "Atualização mise disponível",
      "",
      "Instalada: " .. (item.installed or "?"),
      "Latest: " .. (item.latest or "?"),
      "",
      "Atualizar: mise upgrade " .. item.name,
      "Remover: mise unuse -g " .. item.name,
    }, "\n") }
    return
  end

  if item.kind == "mise" then
    preview = { text = table.concat({
      "Ferramenta mise",
      "",
      trim(item.desc or "") ~= "" and item.desc or "Sem descrição no registry.",
      "",
      "Instala: mise use -g " .. item.name .. "@latest",
    }, "\n") }
    return
  end

  if item.kind == "miseInstalled" then
    preview = { text = table.concat({
      "Gerenciado pelo mise (global)",
      "",
      "Versão: " .. ((item.version ~= nil and item.version ~= "") and item.version or "?"),
      ((item.requested ~= nil and item.requested ~= "") and ("Pedida: " .. item.requested) or ""),
      "",
      "Upgrade: mise upgrade " .. item.name,
      "Remover: mise unuse -g " .. item.name,
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
  rollbackArmed = false
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
  if item.kind == "mise" and item.installed then
    return "instalado"
  end
  if item.kind == "flatpakInstalled" then
    return item.scope == "user" and "user" or "system"
  end
  if item.kind == "webnix" then
    return "nix"
  end
  return nil
end

local function itemRow(item)
  local active = selected ~= nil and selected.key == item.key
  local children = {}

  local titleRow = {}
  if item.glyph ~= nil then
    table.insert(titleRow, ui.glyph({ name = item.glyph, size = 15, color = active and "primary" or "on_surface_variant" }))
  end
  table.insert(titleRow, ui.label({ text = item.name, fontSize = 13, fontWeight = "bold", maxLines = 1, flexGrow = 1 }))
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
local installedMise = {}

local flatApps = nil
local flatLoading = false
local nixApps = nil
local nixLoading = false
local removeError = nil

local webApps = {}
local webAppsLoaded = false

local miseTools = nil
local miseLoading = false
local miseError = nil

local miseOutdated = nil
local miseOutdatedLoading = false
local miseOutdatedError = nil

local updateTasks = {
  {
    key = "upd:flake",
    kind = "updTask",
    glyph = "refresh",
    name = "nix flake update + rebuild",
    id = "nix flake update && sudo nixos-rebuild switch",
    detail = table.concat({
      "Comando:",
      "cd " .. repo .. " && nix flake update && sudo nixos-rebuild switch --flake " .. repo .. "#" .. host,
      "",
      "Atualiza todos os inputs do flake (nixpkgs, home-manager, ...)",
      "junto com o lock e reconstrói o sistema na hora.",
      "A senha do sudo é pedida no terminal.",
    }, "\n"),
    actionLabel = "Atualizar tudo",
    actionGlyph = "refresh",
    onClick = "onUpdateAll",
  },
  {
    key = "upd:switch",
    kind = "updTask",
    glyph = "player-play",
    name = "Rebuild (switch)",
    id = "sudo nixos-rebuild switch",
    detail = table.concat({
      "Comando:",
      "sudo nixos-rebuild switch --flake " .. repo .. "#" .. host,
      "",
      "Reaplica o configuration.nix atual sem atualizar os inputs.",
      "Use depois de mexer em toggles ou config do host.",
      "A senha do sudo é pedida no terminal.",
    }, "\n"),
    actionLabel = "Executar rebuild",
    actionGlyph = "player-play",
    onClick = "onRebuildSwitch2",
  },
  {
    key = "upd:boot",
    kind = "updTask",
    glyph = "device-floppy",
    name = "Rebuild (boot)",
    id = "sudo nixos-rebuild boot",
    detail = table.concat({
      "Comando:",
      "sudo nixos-rebuild boot --flake " .. repo .. "#" .. host,
      "",
      "Prepara a próxima geração sem ativá-la.",
      "Aplica somente no próximo boot (vai para o bootloader).",
      "A senha do sudo é pedida no terminal.",
    }, "\n"),
    actionLabel = "Preparar boot",
    actionGlyph = "device-floppy",
    onClick = "onRebuildBoot",
  },
}

local systemTasks = {
  {
    key = "sys:generations",
    kind = "sysTask",
    glyph = "list-search",
    name = "Listar gerações",
    id = "sudo nixos-rebuild list-generations",
    detail = table.concat({
      "Comando:",
      "sudo nixos-rebuild list-generations",
      "",
      "Mostra o histórico de gerações do perfil system:",
      "o que mudou, quando foi aplicado e qual é a ativa.",
    }, "\n"),
    actionLabel = "Abrir no terminal",
    actionGlyph = "list-search",
    onClick = "onSysGenerations",
  },
  {
    key = "sys:gc",
    kind = "sysTask",
    glyph = "trash",
    name = "Coletar lixo",
    id = "sudo nix-collect-garbage -d",
    detail = table.concat({
      "Comando:",
      "sudo nix-collect-garbage -d",
      "",
      "Remove gerações antigas do perfil system e o lixo",
      "do /nix/store, liberando disco. A geração ativa fica.",
      "A senha do sudo é pedida no terminal.",
    }, "\n"),
    actionLabel = "Executar GC",
    actionGlyph = "trash",
    onClick = "onSysGc",
  },
  {
    key = "sys:config",
    kind = "sysTask",
    glyph = "edit",
    name = "Editar configuration.nix",
    id = "hosts/" .. host .. "/configuration.nix",
    detail = table.concat({
      "Abre no editor:",
      repo .. "/hosts/" .. host .. "/configuration.nix",
      "",
      "É o arquivo que os toggles da tela Aplicativos",
      "escrevem; edite à mão para mudanças fora do padrão.",
    }, "\n"),
    actionLabel = "Abrir editor",
    actionGlyph = "edit",
    onClick = "onSysEditConfig",
  },
  {
    key = "sys:rollback",
    kind = "sysTask",
    glyph = "restore",
    name = "Rollback para geração anterior",
    id = "switch-to-configuration rollback",
    detail = table.concat({
      "Comando:",
      "sudo /run/current-system/bin/switch-to-configuration rollback",
      "",
      "Volta o sistema em execução para a geração anterior",
      "do perfil system. Não apaga nada: as gerações continuam",
      "intactas e você pode voltar a qualquer momento.",
    }, "\n"),
    actionLabel = "Fazer rollback",
    actionGlyph = "restore",
    onClick = "onSysRollback",
    armedLabel = "Confirmar rollback?",
  },
}

local function miseOutdatedItems()
  local items = {}
  for _, row in ipairs(miseOutdated or {}) do
    table.insert(items, {
      key = "mo:" .. row.name,
      kind = "miseOutdated",
      glyph = "download",
      name = row.name,
      id = row.installed .. " → " .. row.latest,
      installed = row.installed,
      latest = row.latest,
    })
  end
  return items
end

local mxQuery = ""
local mxResults = nil
local mxSearching = false
local mxError = nil

selectByKey = function(key)
  local pool = {}
  if view == "install" then
    if instTab == "flatpak" then
      pool = flResults or {}
    elseif instTab == "mise" then
      pool = mxResults or {}
    else
      pool = nxResults or {}
    end
  elseif view == "remove" then
    if removeTab == "flatpak" then
      pool = flatApps or {}
    elseif removeTab == "nix" then
      pool = nixApps or {}
    elseif removeTab == "mise" then
      pool = miseTools or {}
    else
      pool = webApps
    end
  elseif view == "update" then
    pool = {}
    for _, item in ipairs(updateTasks) do
      table.insert(pool, item)
    end
    for _, item in ipairs(miseOutdatedItems()) do
      table.insert(pool, item)
    end
  elseif view == "system" then
    pool = systemTasks
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
  for _, item in ipairs(mxResults or {}) do
    item.installed = installedMise[item.name] == true
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

  noctalia.runAsync("mise ls --installed --json", function(res)
    installedMise = {}
    if res.exitCode == 0 then
      local ok, data = pcall(noctalia.json.decode, res.stdout or "")
      if ok and type(data) == "table" then
        for name in pairs(data) do
          installedMise[name] = true
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

local function miseSearch(q)
  mxSearching = true
  mxError = nil
  render()
  noctalia.runAsync("mise search --no-header " .. shq(q), function(res)
    mxSearching = false
    local items = {}
    if res.exitCode == 0 then
      local seen = {}
      for _, line in ipairs(splitLines(res.stdout or "")) do
        local name = line:match("^(%S+)%s+")
        local desc = line:match("^%S+%s+(.+)$")
        if name ~= nil and name ~= "" and seen[name] == nil then
          seen[name] = true
          table.insert(items, {
            key = "mx:" .. name,
            kind = "mise",
            name = name,
            desc = trim(desc or ""),
            installed = installedMise[name] == true,
          })
        end
      end
    else
      mxError = "mise search falhou: " .. trim(res.stderr):sub(1, 300)
    end
    mxResults = items
    if #items == 0 and mxError == nil then
      mxError = "Nada encontrado para '" .. q .. "' no registry do mise."
    end
    resetSelection()
    render()
  end, 60000)
end

local function miseInstall(name)
  if runInTerminal("mise use -g " .. shq(name .. "@latest")) then
    actionStatus = "mise use -g " .. name .. "@latest no terminal."
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

local function resolveHref(href, origin)
  if href:match("^//") then
    return "https:" .. href
  elseif href:match("^/") then
    return origin .. href
  elseif not href:match("^https?://") then
    return origin .. "/" .. href
  end
  return href
end

local function findAppleTouchIcon(body, origin)
  local head = body:sub(1, 262144)
  local pos = head:find("apple-touch-icon", 1, true)
  if pos == nil then
    return nil
  end
  local winFrom = math.max(1, pos - 600)
  local win = head:sub(winFrom, math.min(#head, pos + 600))
  local relAt = pos - winFrom + 1
  local tagAt = nil
  local scan = 1
  while true do
    local i = win:find("<link", scan, true)
    if i == nil or i > relAt then
      break
    end
    local gt = win:find(">", i, true)
    if gt == nil or gt > relAt then
      tagAt = i
      break
    end
    scan = i + 1
  end
  if tagAt == nil then
    return nil
  end
  local tagEnd = win:find(">", tagAt, true) or #win
  local href = win:sub(tagAt, tagEnd):match('href%s*=%s*["\']([^"\']+)["\']')
  if href == nil then
    return nil
  end
  return resolveHref(href, origin)
end

local function fetchSiteIcon(siteUrl, dest, cb)
  local domain = siteUrl:match("^https?://([^/:?#]+)")
  if domain == nil then
    cb(false)
    return
  end
  local origin = siteUrl:match("^(https?://[^/]+)") or ("https://" .. domain)
  noctalia.http({ url = siteUrl, headers = { "User-Agent: Mozilla/5.0" } }, function(res)
    local urls = {}
    local body = res.body or res.text or res.data
    if res.ok and type(body) == "string" then
      pcall(function()
        local apple = findAppleTouchIcon(body, origin)
        if apple ~= nil then
          table.insert(urls, apple)
        end
      end)
    end
    table.insert(urls, origin .. "/apple-touch-icon.png")
    table.insert(urls, "https://www.google.com/s2/favicons?domain=" .. noctalia.string.urlEncode(domain) .. "&sz=256")
    tryDownloadSeq(urls, dest, cb)
  end)
end

local function loadNixWebApps()
  local items = {}
  local manifest = noctalia.readFile("/etc/hamra/apps.json")
  if type(manifest) ~= "string" or trim(manifest) == "" then
    return items
  end
  local ok, data = pcall(noctalia.json.decode, manifest)
  if not ok or type(data) ~= "table" or type(data.webapps) ~= "table" then
    return items
  end
  local names = {}
  for name in pairs(data.webapps) do
    table.insert(names, name)
  end
  table.sort(names)
  for _, name in ipairs(names) do
    local app = data.webapps[name]
    if type(app) == "table" and type(app.url) == "string" then
      table.insert(items, {
        key = "webnix:" .. name,
        kind = "webnix",
        nixKey = name,
        name = (type(app.name) == "string" and app.name) or name,
        url = app.url,
      })
    end
  end
  return items
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
  for _, item in ipairs(loadNixWebApps()) do
    table.insert(webApps, item)
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

local function writeWebAppDesktop(name, url, iconValue)
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
  if type(check) ~= "string" or not check:find("Name=" .. desktopEscape(name), 1, true) then
    return nil
  end
  return desktopFile
end

local function setWebAppIcon(desktopFile, iconValue)
  local content = noctalia.readFile(desktopFile)
  if type(content) ~= "string" then
    return false
  end
  content = content:gsub("Icon=[^\n]*", "Icon=" .. iconValue, 1)
  noctalia.writeFile(desktopFile, content)
  return true
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
  waStatus = "Criando lançador..."
  render()

  local iconValue = safeIconName(name)
  local desktopFile = writeWebAppDesktop(name, url, "text-html")
  waCreating = false

  if desktopFile == nil then
    waStatus = nil
    notifyError("Não consegui escrever " .. desktopDir() .. "/" .. name .. ".desktop")
    render()
    return
  end

  waStatus = "Criado! Buscando ícone do site..."
  notify("Web app '" .. name .. "' criado no launcher.")
  waName = ""
  waUrl = ""
  loadWebApps()
  render()

  local dest = iconDir() .. "/" .. iconValue .. ".png"
  noctalia.mkdirAll(iconDir())
  fetchSiteIcon(url, dest, function(ok)
    if ok and setWebAppIcon(desktopFile, iconValue) then
      waStatus = "Criado com ícone do site."
    else
      waStatus = "Criado com ícone genérico."
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
  if selected.kind == "mise" then
    if selected.installed then
      return { label = "Já está instalado", glyph = "check", enabled = false, onClick = "onInstGo" }
    end
    return { label = "Instalar (mise use -g)", glyph = "download", onClick = "onInstGo" }
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
  elseif selected.kind == "mise" then
    miseInstall(selected.name)
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
    { id = "mise", label = "Mise", glyph = "tool" },
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
  elseif instTab == "mise" then
    table.insert(children, searchBox(
      "inst-search-mise",
      mxQuery,
      "Buscar ferramenta no registry do mise (ex.: node)...",
      function(v) mxQuery = v or "" end,
      "onMxSubmit",
      "onMxSearch",
      mxSearching
    ))

    local rows = {}
    if mxResults ~= nil then
      for _, item in ipairs(mxResults) do
        table.insert(rows, itemRow(item))
      end
    end
    table.insert(children, splitPane(
      listOrMessage(rows, mxSearching, mxError, "Busque uma ferramenta (node, python, go...) para ver os resultados."),
      selectionPane({
        action = installAction(),
        status = actionStatus,
        empty = "Passe o mouse num resultado para ver a descrição aqui.",
      })
    ))
    table.insert(children, hint("Instala com `mise use -g <ferramenta>@latest`; fica no PATH na frente do Nix dentro do shell e é gerenciado em Remover › Mise."))
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

local function loadMiseTools()
  miseLoading = true
  render()
  noctalia.runAsync("mise ls --installed --json", function(res)
    miseLoading = false
    miseError = nil
    local items = {}
    if res.exitCode == 0 then
      local ok, data = pcall(noctalia.json.decode, res.stdout or "")
      if ok and type(data) == "table" then
        for name, versions in pairs(data) do
          local v = type(versions) == "table" and versions[1] or nil
          local requested = (v ~= nil and type(v) == "table") and v.requested_version or nil
          table.insert(items, {
            key = "imx:" .. name,
            kind = "miseInstalled",
            name = name,
            version = (v ~= nil and type(v) == "table" and v.version) or "",
            requested = requested or "",
          })
        end
      end
    else
      miseError = "mise ls falhou: " .. trim(res.stderr):sub(1, 200)
    end
    table.sort(items, function(a, b)
      return a.name < b.name
    end)
    miseTools = items
    if selected ~= nil and selected.kind == "miseInstalled" then
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

local function miseRemove(tool)
  actionStatus = "Removendo " .. tool.name .. " do mise..."
  render()
  noctalia.runAsync("mise unuse -g " .. shq(tool.name) .. " && mise uninstall -y " .. shq(tool.name), function(res)
    if res.exitCode == 0 then
      actionStatus = tool.name .. " removido do mise."
      notify(tool.name .. " removido do mise.")
    else
      actionStatus = "Falha: " .. trim(res.stderr):sub(1, 200)
      notifyError("Falha ao remover " .. tool.name .. ": " .. trim(res.stderr))
    end
    resetSelection()
    loadMiseTools()
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
  if selected.kind == "miseInstalled" then
    return { label = "Remover (mise)", glyph = "trash", variant = "destructive", onClick = "onRmGo" }
  end
  if selected.kind == "web" then
    return { label = "Remover web app", glyph = "trash", variant = "destructive", onClick = "onRmGo" }
  end
  if selected.kind == "webnix" then
    return { label = "Gerido pelo Nix (declarativo)", glyph = "package", enabled = false, onClick = "onRmGo" }
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
  elseif selected.kind == "miseInstalled" then
    miseRemove(selected)
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
    { id = "mise", label = "Mise", glyph = "tool" },
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
  elseif removeTab == "mise" then
    loading = miseLoading
    err = miseError
    empty = "Nenhuma ferramenta instalada pelo mise."
    if miseTools == nil then
      loading = true
    else
      for _, item in ipairs(miseTools) do
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
    empty = "Nenhum web app (criado no painel ou declarado no Nix)."
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

local function loadMiseOutdated()
  miseOutdatedLoading = true
  miseOutdatedError = nil
  render()
  noctalia.runAsync("mise outdated --json", function(res)
    miseOutdatedLoading = false
    local rows = {}
    if res.exitCode ~= 0 then
      miseOutdatedError = "mise outdated falhou: " .. trim(res.stderr):sub(1, 200)
    else
      local ok, data = pcall(noctalia.json.decode, res.stdout or "")
      if ok and type(data) == "table" then
        for name, entry in pairs(data) do
          local installedV = nil
          local latestV = nil
          if type(entry) == "table" then
            if type(entry.current) == "string" then
              installedV = entry.current
              latestV = (type(entry.latest) == "string" and entry.latest)
                or (type(entry.bump) == "string" and entry.bump)
                or entry.current
            elseif type(entry[1]) == "table" then
              installedV = entry[1].version
              latestV = entry[1].latest or entry[1].bump or entry[1].version
            end
          end
          rows[#rows + 1] = { name = name, installed = installedV or "?", latest = latestV or "?" }
        end
      end
    end
    table.sort(rows, function(a, b)
      return a.name < b.name
    end)
    miseOutdated = rows
    render()
  end, 60000)
end

local function updateAction()
  if selected == nil then
    return nil
  end
  if selected.kind == "updTask" then
    return {
      label = selected.actionLabel,
      glyph = selected.actionGlyph,
      variant = "primary",
      onClick = selected.onClick,
    }
  end
  if selected.kind == "miseOutdated" then
    local name = selected.name
    return {
      label = "mise upgrade " .. name,
      glyph = "download",
      onClick = function()
        onMiseUpgrade(name)
      end,
    }
  end
  return nil
end

local function renderUpdate()
  local children = { header("Atualizar", {
    ui.button({ glyph = "reload", variant = "ghost", tooltip = "Recarregar lista mise", onClick = "onMiseReload", enabled = not miseOutdatedLoading }),
  }) }

  table.insert(children, ui.label({
    text = "Host: " .. host .. "  ·  " .. repo,
    fontSize = 12,
    color = "on_surface_variant",
  }))

  local rows = {
    ui.label({ text = "Sistema", fontSize = 14, fontWeight = "bold", color = "primary" }),
  }
  for _, task in ipairs(updateTasks) do
    table.insert(rows, itemRow(task))
  end

  table.insert(rows, ui.label({ text = "Ferramentas mise", fontSize = 14, fontWeight = "bold", color = "primary" }))
  if miseOutdatedLoading then
    table.insert(rows, ui.label({ text = "Consultando mise outdated...", color = "on_surface_variant", fontSize = 11 }))
  elseif miseOutdatedError ~= nil then
    table.insert(rows, ui.label({ text = miseOutdatedError, color = "error", fontSize = 11, maxLines = 3 }))
    table.insert(rows, ui.button({ text = "Tentar de novo", onClick = "onMiseReload" }))
  elseif miseOutdated == nil then
    table.insert(rows, ui.label({ text = "Carregando...", color = "on_surface_variant", fontSize = 11 }))
    loadMiseOutdated()
  elseif #miseOutdated == 0 then
    table.insert(rows, ui.label({ text = "Todas as ferramentas mise estão atualizadas.", color = "on_surface_variant", fontSize = 11 }))
  else
    for _, item in ipairs(miseOutdatedItems()) do
      table.insert(rows, itemRow(item))
    end
  end

  table.insert(children, splitPane(rows, selectionPane({
    action = updateAction(),
    status = actionStatus,
    empty = "Passe o mouse numa ação para ver o comando aqui.",
  })))

  table.insert(children, hint("O rebuild roda num terminal porque o sudo pede sua senha. O flake update também atualiza o lock do Home Manager. O mise upgrade abre um terminal para você acompanhar."))

  return ui.column({ flexGrow = 1, gap = 10, align = "stretch" }, children)
end

-- ── Sistema ─────────────────────────────────────────────────────────────────

local sysInfo = nil
local sysLoading = false

local function loadSystemInfo()
  sysLoading = true
  render()
  local cmd = "readlink -f /run/current-system 2>/dev/null; echo ---; nixos-version 2>/dev/null; echo ---; uname -r; echo ---; cut -d' ' -f1 /proc/uptime"
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
    local up = tonumber(((parts[4] or ""):match("^[%d.]+")))
    local uptime = "?"
    if up ~= nil then
      local h = math.floor(up / 3600)
      local m = math.floor((up % 3600) / 60)
      uptime = (h > 0 and (h .. "h ") or "") .. m .. "m"
    end
    sysInfo = {
      generation = parts[1] or "?",
      nixosVersion = parts[2] or "?",
      kernel = parts[3] or "?",
      uptime = uptime,
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

local function systemAction()
  if selected == nil or selected.kind ~= "sysTask" then
    return nil
  end
  local label = selected.actionLabel
  local variant = "primary"
  if selected.key == "sys:rollback" then
    label = rollbackArmed and selected.armedLabel or selected.actionLabel
    variant = rollbackArmed and "primary" or "outline"
  end
  return { label = label, glyph = selected.actionGlyph, variant = variant, onClick = selected.onClick }
end

local function renderSystem()
  local children = { header("Sistema", {
    ui.button({ glyph = "reload", variant = "ghost", tooltip = "Recarregar info", onClick = "onSysReload" }),
  }) }

  local infoBlock = {}
  if sysLoading then
    table.insert(infoBlock, ui.label({ text = "Coletando info...", color = "on_surface_variant", fontSize = 11 }))
  elseif sysInfo ~= nil then
    table.insert(infoBlock, infoRow("Kernel", sysInfo.kernel))
    table.insert(infoBlock, infoRow("NixOS", sysInfo.nixosVersion))
    table.insert(infoBlock, infoRow("Uptime", sysInfo.uptime))
    table.insert(infoBlock, infoRow("Geração", sysInfo.generation))
  else
    table.insert(infoBlock, ui.button({ text = "Carregar info", glyph = "reload", onClick = "onSysReload" }))
  end

  local rows = {
    ui.label({ text = "Info do sistema", fontSize = 14, fontWeight = "bold", color = "primary" }),
    ui.column({
      gap = 6,
      padding = 10,
      paddingH = 12,
      fill = "surface",
      radius = 8,
      border = "outline",
      borderWidth = 1,
    }, infoBlock),
    ui.label({ text = "Tarefas", fontSize = 14, fontWeight = "bold", color = "primary" }),
  }
  for _, task in ipairs(systemTasks) do
    table.insert(rows, itemRow(task))
  end

  table.insert(children, splitPane(rows, selectionPane({
    action = systemAction(),
    status = actionStatus,
    empty = "Passe o mouse numa tarefa para ver o comando aqui.",
  })))

  table.insert(children, hint("Rollback troca o sistema em execução para a geração anterior do perfil system."))

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
      ui.glyph({ name = "adjustments", size = 18, color = "primary" }),
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
  resetSelection()
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
    if miseTools == nil and not miseLoading then
      loadMiseTools()
    end
    if not webAppsLoaded then
      loadWebApps()
    end
  elseif id == "update" and miseOutdated == nil and not miseOutdatedLoading then
    loadMiseOutdated()
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

function onSshImport()
  sshImport()
end

function onSshTest()
  sshTestKey()
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

function onGpgImport()
  gpgImport()
end

function onGpgTest()
  gpgTest()
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

function onMxSearch()
  if trim(mxQuery) ~= "" then
    miseSearch(mxQuery)
  end
end

function onMxSubmit(value)
  mxQuery = trim(value or mxQuery)
  if mxQuery ~= "" then
    miseSearch(mxQuery)
  end
end

function onMiseReload()
  loadMiseOutdated()
end

function onMiseUpgrade(name)
  if runInTerminal("mise upgrade " .. shq(name)) then
    notify("mise upgrade " .. name .. " disparado no terminal.")
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
  elseif removeTab == "mise" then
    loadMiseTools()
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
--   search <origem> <q> busca e mostra o preview (flatpak | nix | mise)
--   select <key>       seleciona um item para o preview (fl:, nx:, ifl:, inx:, web:, upd:, sys:, mo:)
--   webapp-create <nome> <url>   cria um web app (mesmo fluxo do botão Criar)
--   webapp-remove <arquivo>      remove um web app imperativo (ex.: YouTube.desktop)
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
    elseif origin == "mise" then
      mxQuery = q
      instTab = "mise"
      openView("install")
      miseSearch(q)
    end
    return
  end

  if e == "webapp-create" then
    local name, url = p:match("^(%S+)%s+(%S+)$")
    if name ~= nil then
      waName = name
      waUrl = url
      instTab = "web"
      openView("install")
      createWebApp()
    end
    return
  end

  if e == "webapp-remove" then
    if not webAppsLoaded then
      loadWebApps()
    end
    for _, item in ipairs(webApps) do
      if item.kind == "web" and (item.file == p or item.file == p .. ".desktop" or item.name == p) then
        removeWebApp(item)
        return
      end
    end
    notifyError("Web app não encontrado: " .. p)
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
    instTab = (type(tab) == "string" and (tab == "nix" or tab == "mise")) and tab or "flatpak"
    resetSelection()
    if instTab == "nix" then
      nxQuery = q
      openView("install")
      nixSearch(q)
    elseif instTab == "mise" then
      mxQuery = q
      openView("install")
      miseSearch(q)
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
