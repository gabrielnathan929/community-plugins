--!nonstrict
-- Hamra Control bar widget: opens the control-center panel on click and the
-- Install view on right click. Presentation comes from the widget settings
-- declared in plugin.toml (icon + optional label).

local PANEL_ID = "gabrielnathan929/hamra-control:main"

local glyph = noctalia.getConfig("glyph")
local showLabel = noctalia.getConfig("show_label")
local label = noctalia.getConfig("label")

local function render()
  barWidget.setGlyph(if type(glyph) == "string" and glyph ~= "" then glyph else "adjustments")
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

function onRightClick()
  noctalia.state.set("hamra_view", "install")
  noctalia.togglePanel(PANEL_ID)
end

function update()
  noctalia.setUpdateInterval(300000)
  render()
end

render()
