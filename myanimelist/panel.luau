--!nonstrict

local API_URL = "https://graphql.anilist.co"
local PER_PAGE = 15
local DOWNLOAD_SLOTS = 6
local CARD_WIDTH = 175
local CARD_HEIGHT = 260
local CARD_GAP = 12
local CONTENT_PADDING = 28
local SCROLLBAR_RESERVE = 22

local PANEL_WIDTH = 1032
local GRID_WIDTH = PANEL_WIDTH - CONTENT_PADDING * 2 - SCROLLBAR_RESERVE * 2

local function gridLayout()
  local columns = math.max(1, math.floor((GRID_WIDTH + CARD_GAP) / (CARD_WIDTH + CARD_GAP)))
  local width = math.floor((GRID_WIDTH - CARD_GAP * (columns - 1)) / columns)
  return columns, width
end

local DEBUG = false
local function debugLog(fmt, ...)
  if DEBUG then
    noctalia.log(string.format("[myanimelist] " .. fmt, ...))
  end
end

local COVER_ROOT = noctalia.expandPath("~/noctalia/covers")
noctalia.mkdirAll(COVER_ROOT)
noctalia.mkdirAll(COVER_ROOT .. "/anime")
noctalia.mkdirAll(COVER_ROOT .. "/manga")

local downloadedCovers = {}
local coversBeingDownloaded = {}
local coverFailed = {}
local coverDownloadQueue = {}
local activeDownloads = 0

local function coverPath(item)
  return COVER_ROOT .. "/" .. string.lower(item.mediaType) .. "/" .. tostring(item.id) .. ".jpg"
end

local function coverKey(item)
  return tostring(item.id) .. ":" .. string.lower(item.mediaType)
end

local function drainCoverQueue()
  while activeDownloads < DOWNLOAD_SLOTS and #coverDownloadQueue > 0 do
    local item = table.remove(coverDownloadQueue, 1)
    local key = coverKey(item)
    if not downloadedCovers[key] and not coversBeingDownloaded[key] and not coverFailed[key] then
      coversBeingDownloaded[key] = true
      activeDownloads = activeDownloads + 1
      local destination = coverPath(item)
      noctalia.mkdirAll(COVER_ROOT .. "/" .. string.lower(item.mediaType))
      debugLog("downloading cover id=%s kind=%s -> %s", tostring(item.id), item.mediaType, destination)
      local ok = noctalia.download(item.cover, destination, function(success)
        activeDownloads = activeDownloads - 1
        coversBeingDownloaded[key] = nil
        if success then
          downloadedCovers[key] = destination
          render()
        else
          coverFailed[key] = true
          render()
        end
        drainCoverQueue()
      end)
      if not ok then
        activeDownloads = activeDownloads - 1
        coversBeingDownloaded[key] = nil
        coverFailed[key] = true
        drainCoverQueue()
      end
    end
  end
end

local function requestCover(item)
  if item.cover == nil then return end
  local key = coverKey(item)
  if downloadedCovers[key] or coversBeingDownloaded[key] or coverFailed[key] then return end
  debugLog("queued cover id=%s kind=%s", tostring(item.id), item.mediaType)
  table.insert(coverDownloadQueue, item)
  drainCoverQueue()
end

local function buildAniListQuery(search, mediaType, pageNumber)
  local typeFilter = ""
  if mediaType ~= nil then
    typeFilter = ", type: " .. mediaType
  end
  local gql = ("query ($q: String, $page: Int) { Page (page: $page, perPage: " .. PER_PAGE .. ") { media (search: $q" .. typeFilter .. ") { id idMal type title { romaji english native } coverImage { large } } } }")
  local function escape(s)
    return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
  end
  return '{"query":"' .. escape(gql) .. '","variables":{"q":"' .. escape(search) .. '","page":' .. pageNumber .. '}}'
end

local function parseAniListResponse(response)
  local raw = response.body or response.text or response.data
  if raw == nil then return nil, "empty response from AniList" end
  local success, data = pcall(noctalia.json.decode, raw)
  if not success then return nil, "could not parse AniList response" end
  if type(data.data) ~= "table" or type(data.data.Page) ~= "table" then
    return nil, "unexpected AniList response structure"
  end
  local results = {}
  for _, entry in ipairs(data.data.Page.media) do
    local title = (type(entry.title) == "table" and (entry.title.english or entry.title.romaji or entry.title.native)) or tostring(entry.id)
    local mediaType = (entry.type == "MANGA") and "MANGA" or "ANIME"
    results[#results + 1] = {
      id = entry.id,
      idMal = entry.idMal,
      mediaType = mediaType,
      title = title,
      cover = (type(entry.coverImage) == "table" and entry.coverImage.large) or nil,
    }
  end
  local pageInfo = data.data.Page.pageInfo
  local totalPages = (type(pageInfo) == "table" and pageInfo.lastPage) or 1
  return results, nil, totalPages
end

local function myAnimeListLink(item)
  if item.idMal then
    local kind = (item.mediaType == "MANGA") and "manga" or "anime"
    return "https://myanimelist.net/" .. kind .. "/" .. tostring(item.idMal)
  end
  return "https://anilist.co/" .. string.lower(item.mediaType) .. "/" .. tostring(item.id)
end

local searchQuery = ""
local searchResults = {}
local isSearching = false
local searchError = ""
local currentPage = 1
local totalPages = 1
local selectedCategory = "ANIME"

local function resultCard(index, item, cardWidth)
  local children = {}
  local cached = downloadedCovers[coverKey(item)]
  if cached ~= nil then
    children[#children + 1] = ui.image({
      path = cached, width = cardWidth, height = CARD_HEIGHT,
      fit = "cover", radius = 8, onClick = "onOpenItem" .. index,
    })
  elseif coverFailed[coverKey(item)] then
    children[#children + 1] = ui.box({
      width = cardWidth, height = CARD_HEIGHT,
      fill = "error_container", radius = 8, onClick = "onOpenItem" .. index,
    })
  else
    children[#children + 1] = ui.box({
      width = cardWidth, height = CARD_HEIGHT,
      fill = "surface_variant", radius = 8, onClick = "onOpenItem" .. index,
    })
    requestCover(item)
  end
  children[#children + 1] = ui.label({
    text = item.title, fontSize = 12, maxLines = 2, maxWidth = cardWidth, textAlign = "center",
  })
  children[#children + 1] = ui.label({
    text = item.mediaType, fontSize = 10, color = "on_surface_variant", maxLines = 1, maxWidth = cardWidth, textAlign = "center",
  })
  children[#children + 1] = ui.label({
    text = "MyAnimeList", fontSize = 9, color = "primary", maxLines = 1, maxWidth = cardWidth, textAlign = "center",
  })
  return ui.column({ gap = 6, width = cardWidth, align = "center" }, children)
end

local function buildResultsGrid(items)
  local columns, cardWidth = gridLayout()
  local cards = {}
  for index, item in ipairs(items) do
    cards[#cards + 1] = resultCard(index, item, cardWidth)
  end
  local rows = {}
  for start = 1, #cards, columns do
    local row = {}
    for offset = start, math.min(start + columns - 1, #cards) do
      row[#row + 1] = cards[offset]
    end
    rows[#rows + 1] = ui.row({ gap = CARD_GAP, align = "start" }, row)
  end
  return ui.column({ gap = 16, align = "center" }, rows)
end

function render()
  local children = {}

  children[#children + 1] = ui.label({
    text = "MyAnimeList", fontSize = 16, fontWeight = "bold", color = "primary", maxLines = 1,
  })

  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.input({
      key = "media_search", placeholder = "Search anime or manga...",
      value = searchQuery, onChange = "onSearchChange", onSubmit = "onSearchSubmitted",
      focus = true, flexGrow = 1,
    }),
    ui.button({ text = "Search", onClick = "onSearchClicked", enabled = not isSearching }),
  })

  children[#children + 1] = ui.row({ gap = 8, align = "center" }, {
    ui.button({ text = "Anime", onClick = "onFilterAnime", variant = (selectedCategory == "ANIME") and "outline" or "ghost" }),
    ui.button({ text = "Manga", onClick = "onFilterManga", variant = (selectedCategory == "MANGA") and "outline" or "ghost" }),
    ui.button({ text = "Both", onClick = "onFilterBoth", variant = (selectedCategory == nil) and "outline" or "ghost" }),
  })

  if searchError ~= "" then
    children[#children + 1] = ui.label({ text = searchError, color = "error" })
  end

  if #searchResults > 0 then
    children[#children + 1] = ui.scroll({ gap = 16, flexGrow = 1 }, {
      buildResultsGrid(searchResults),
    })
  else
    children[#children + 1] = ui.scroll({ flexGrow = 1 }, {
      ui.label({
        text = isSearching and "Loading..." or (#searchQuery > 0 and "No results" or "Use the search box"),
        color = "on_surface_variant",
      }),
    })
  end

  if #searchResults > 0 and totalPages > 1 then
    children[#children + 1] = ui.row({ gap = 8, align = "center", justify = "center" }, {
      ui.button({ text = "Prev", onClick = "onPreviousPage", enabled = currentPage > 1 }),
      ui.label({ text = "Page " .. currentPage .. " / " .. totalPages, color = "on_surface_variant" }),
      ui.button({ text = "Next", onClick = "onNextPage", enabled = currentPage < totalPages }),
    })
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16, align = "stretch" }, children))
end

local function performSearch()
  searchError = ""
  if #searchQuery < 2 then
    searchResults = {}
    searchError = "Type at least 2 characters."
    render()
    return
  end
  isSearching = true
  render()
  local apiQuery = buildAniListQuery(searchQuery, selectedCategory, currentPage)
  noctalia.http({
    url = API_URL,
    method = "POST",
    headers = {
      "Content-Type: application/json",
      "User-Agent: Noctalia-MediaSearch/0.2 (gabrielnathan929)",
    },
    body = apiQuery,
  }, function(response)
    isSearching = false
    if not response.ok then
      searchError = "Request failed (HTTP " .. tostring(response.status) .. ")"
      searchResults = {}
      render()
      return
    end
    local items, parseError, pages = parseAniListResponse(response)
    if parseError then
      searchError = parseError
      searchResults = {}
      render()
      return
    end
    searchResults = items
    totalPages = pages
    if #items == 0 then
      searchError = "No results for '" .. searchQuery .. "'."
    end
    render()
    for _, item in ipairs(items) do
      requestCover(item)
    end
  end)
end

function onSearchClicked()
  currentPage = 1
  performSearch()
end

function onOpen(_)
  local preset = noctalia.state.get("myanimelist_query")
  if preset and preset ~= "" then
    searchQuery = preset
    noctalia.state.set("myanimelist_query", "")
    performSearch()
    return
  end
  render()
end

function onSearchSubmitted(value)
  searchQuery = value or searchQuery
  currentPage = 1
  performSearch()
end

function onSearchChange(value)
  searchQuery = value
  currentPage = 1
end

function onFilterAnime()
  selectedCategory = "ANIME"
  currentPage = 1
  if #searchQuery >= 2 then performSearch() else render() end
end

function onFilterManga()
  selectedCategory = "MANGA"
  currentPage = 1
  if #searchQuery >= 2 then performSearch() else render() end
end

function onFilterBoth()
  selectedCategory = nil
  currentPage = 1
  if #searchQuery >= 2 then performSearch() else render() end
end

function onPreviousPage()
  if currentPage > 1 then
    currentPage = currentPage - 1
    performSearch()
  end
end

function onNextPage()
  if currentPage < totalPages then
    currentPage = currentPage + 1
    performSearch()
  end
end

local function openItemAtIndex(index)
  local item = searchResults[index]
  if item then
    debugLog("opening item %d: %s", index, item.title)
    noctalia.runAsync("xdg-open " .. myAnimeListLink(item), function() end)
  end
end

function onOpenItem1() openItemAtIndex(1) end
function onOpenItem2() openItemAtIndex(2) end
function onOpenItem3() openItemAtIndex(3) end
function onOpenItem4() openItemAtIndex(4) end
function onOpenItem5() openItemAtIndex(5) end
function onOpenItem6() openItemAtIndex(6) end
function onOpenItem7() openItemAtIndex(7) end
function onOpenItem8() openItemAtIndex(8) end
function onOpenItem9() openItemAtIndex(9) end
function onOpenItem10() openItemAtIndex(10) end
function onOpenItem11() openItemAtIndex(11) end
function onOpenItem12() openItemAtIndex(12) end
function onOpenItem13() openItemAtIndex(13) end
function onOpenItem14() openItemAtIndex(14) end
function onOpenItem15() openItemAtIndex(15) end
