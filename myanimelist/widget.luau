--!nonstrict
-- MyAnimeList bar widget: opens the search browser panel on click.
-- Presentation comes from the widget settings declared in plugin.toml
-- (icon + optional label).

local PANEL_ID = "gabrielnathan929/myanimelist:browser"

local glyph = noctalia.getConfig("glyph")
local showLabel = noctalia.getConfig("show_label")
local label = noctalia.getConfig("label")

local function render()
  barWidget.setGlyph(if type(glyph) == "string" and glyph ~= "" then glyph else "star")
  if showLabel and type(label) == "string" and label ~= "" then
    barWidget.setText(label)
  else
    barWidget.setText("")
  end
  barWidget.setTooltip(noctalia.tr("widget.tooltip"))
end

function onClick()
  noctalia.togglePanel(PANEL_ID)
end

function update()
  noctalia.setUpdateInterval(300000)
  render()
end

render()
