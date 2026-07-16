--!nonstrict

local PANEL_ID = "gabrielnathan929/myanimelist:browser"
local GLYPH = "star"

function onQuery(query)
  local text = noctalia.string.trim(query)
  local rows = {}

  if text == "" then
    rows[#rows + 1] = {
      id = "open",
      title = "MyAnimeList",
      subtitle = "Search anime & manga (results open on MyAnimeList)",
      icon = GLYPH,
    }
  else
    rows[#rows + 1] = {
      id = "search:" .. text,
      title = "Search MyAnimeList: " .. text,
      subtitle = "Open Media Search with this query",
      icon = GLYPH,
    }
  end

  launcher.setResults(query, rows)
end

function onActivate(id)
  if id == "open" then
    noctalia.togglePanel(PANEL_ID)
    return
  end

  local q = id:match("^search:(.+)$")
  if q ~= nil then
    noctalia.state.set("myanimelist_query", q)
    noctalia.togglePanel(PANEL_ID)
  end
end
