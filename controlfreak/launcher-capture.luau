--!nonstrict

-- /cap: escolhe uma ação de captura. Cada linha mostra o que ela faz, e a
-- primeira opção vira "Parar gravação" enquanto houver uma gravação rodando.

local GSR_PATTERN = "^(/nix/store/.*-)?gpu-screen-recorder"
local RECORD_CATEGORY = "Gravar"
local SHOT_CATEGORY = "Captura de tela"
local CHECK_TTL_MS = 2000

local ACTIONS = {
  {
    id = "record:none",
    title = "Gravar sem áudio",
    subtitle = "Vídeo apenas",
    glyph = "volume-off",
    category = RECORD_CATEGORY,
  },
  {
    id = "record:desktop",
    title = "Gravar áudio do sistema",
    subtitle = "Vídeo + áudio do desktop",
    glyph = "volume",
    category = RECORD_CATEGORY,
  },
  {
    id = "record:both",
    title = "Gravar sistema + microfone",
    subtitle = "Vídeo + áudio do desktop + microfone",
    glyph = "microphone",
    category = RECORD_CATEGORY,
  },
  {
    id = "record:webcam",
    title = "Gravar sistema + microfone + webcam",
    subtitle = "Vídeo + áudio do desktop + microfone + webcam flutuante",
    glyph = "camera",
    category = RECORD_CATEGORY,
  },
  {
    id = "screenshot:region",
    title = "Screenshot: região",
    subtitle = "Selecionar uma área da tela",
    glyph = "crop",
    category = SHOT_CATEGORY,
  },
  {
    id = "screenshot:window",
    title = "Screenshot: janela",
    subtitle = "A janela em foco",
    glyph = "app-window",
    category = SHOT_CATEGORY,
  },
  {
    id = "screenshot:monitor",
    title = "Screenshot: monitor",
    subtitle = "O monitor em foco",
    glyph = "device-desktop",
    category = SHOT_CATEGORY,
  },
  {
    id = "screenshot:annotate",
    title = "Screenshot: anotar região",
    subtitle = "Região com o editor de anotações",
    glyph = "pencil",
    category = SHOT_CATEGORY,
  },
}

local recording = false
local lastQuery = ""
local checking = false
local lastCheckMs = 0

local function trim(s)
  return noctalia.string.trim(s or "")
end

local function rowsFor(text)
  local rows = {}

  if recording then
    rows[#rows + 1] = {
      id = "stop",
      title = "Parar gravação",
      subtitle = "Encerrar a gravação em andamento",
      glyph = "player-stop",
      category = RECORD_CATEGORY,
      score = 100,
    }
  end

  for _, action in ipairs(ACTIONS) do
    local score
    if text == "" then
      score = 1
    else
      score = noctalia.fuzzyScore(text, action.title)
      if score == nil then
        local s = noctalia.fuzzyScore(text, action.subtitle)
        if s ~= nil then
          score = s * 0.5
        end
      end
    end
    if score ~= nil then
      rows[#rows + 1] = {
        id = action.id,
        title = action.title,
        subtitle = action.subtitle,
        glyph = action.glyph,
        category = action.category,
        score = score,
      }
    end
  end

  return rows
end

local function publish()
  local rows = rowsFor(trim(lastQuery))
  if #rows == 0 then
    rows[#rows + 1] = { id = "", title = "Nada encontrado", glyph = "search-off" }
  end
  launcher.setResults(lastQuery, rows)
end

local function checkRecording()
  if checking then
    return
  end
  checking = true
  local ok = noctalia.runAsync({"pgrep", "-f", GSR_PATTERN}, function(result)
    checking = false
    lastCheckMs = noctalia.nowMs()
    local now = result.exitCode == 0
    if now ~= recording then
      recording = now
      publish()
    end
  end)
  if not ok then
    checking = false
  end
end

local function run(argv)
  local ok = noctalia.runAsync(argv, function(result)
    lastCheckMs = 0
    if result.exitCode ~= 0 then
      local err = trim(result.stderr)
      noctalia.notifyError("Captura", err ~= "" and err or ("Falhou: " .. table.concat(argv, " ")))
    end
  end)
  if not ok then
    noctalia.notifyError("Captura", "Não consegui executar " .. table.concat(argv, " "))
  end
end

function onQuery(query)
  lastQuery = query
  publish()
  if noctalia.nowMs() - lastCheckMs > CHECK_TTL_MS then
    checkRecording()
  end
end

function onActivate(id)
  if type(id) ~= "string" or id == "" then
    return
  end
  if id == "stop" then
    run({"capture", "stop"})
    return
  end
  local kind, mode = string.match(id, "^(%a+):(%a+)$")
  if kind ~= nil then
    run({"capture", kind, mode})
  end
end

function onIpc(event)
  if event == "refresh" then
    lastCheckMs = 0
    checkRecording()
    publish()
  end
end
