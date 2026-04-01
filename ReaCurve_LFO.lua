-- @description ReaCurve - LFO (Polygon LFO Generator)
-- @author sailok
-- @version 1.0.0
-- @about
--   Polygon LFO generator — create complex modulation shapes using
--   geometric patterns (polygon sides, cycles, curves).
--   Can be run standalone or as part of the ReaCurve Suite.
--
--   Requires: ReaImGui extension, SWS/S&M extension, js_ReaScriptAPI
--   Install the "ReaCurve Suite" package to get all dependencies.
-- @link https://github.com/sailok-audio/ReaCurve

-- ============================================================
--   ReaCurve_LFO.lua
--   Can be launched standalone or imported as a module in the Hub
-- ============================================================
local script_name = "Polygon LFO Generator"
local LFO_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]:match('^.+[/\\]'):gsub('\\','/')
package.path = _script_path .. "lib/LFO/?.lua;"
            .. _script_path .. "lib/RAND/?.lua;"
            .. _script_path .. "lib/UI/?.lua;"
            .. _script_path .. "lib/CommonFunction/?.lua;"
            .. _script_path .. "lib/CommonFunction/UI/?.lua;"
            .. package.path

-- ── Dependency check (standalone only) ───────────────────────
if not SLK_HUB_IN_USE then
  local missing = {}
  if not reaper.ImGui_CreateContext then
    missing[#missing + 1] = "ReaImGui  (Extensions > ReaImGui)"
  end
  if not reaper.SNM_GetIntConfigVar then
    missing[#missing + 1] = "SWS/S&M Extension  (Extensions > SWS/S&M Extension)"
  end
  if not reaper.JS_ReaScriptAPI_Version then
    missing[#missing + 1] = "js_ReaScriptAPI  (Extensions > js_ReaScriptAPI)"
  end
  if #missing > 0 then
    reaper.MB(
      script_name .. " requires the following missing package(s):\n\n"
      .. table.concat(missing, "\n")
      .. "\n\nInstall them via ReaPack and restart REAPER.",
      "ReaCurve — Missing dependencies", 0)
    return
  end
end

local LFOConfig   = require("LFOConfig")
local LFOState    = require("LFOState")
local LFOPanels   = require("LFOPanel")
local Logger      = require("Logger")
local Theme       = require("Theme")
local ReaperUtils = require("ReaperUtils")
local LFOPresets  = require("LFOPresets")
local Widgets     = require("Widgets")

-- ── MAIN DRAW FUNCTION (called by Hub or Standalone) ──────────
function LFO_Tool.drawUI(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local ctx_info = ReaperUtils.getContextInfo()

  -- Top margin (space between hub border and first element)
  if SLK_HUB_IN_USE then reaper.ImGui_Dummy(ctx, 1, 4) end

  -- PRESETS
  Widgets.drawSectionSep(ctx, dl, "PRESETS")
  LFOPanels.drawPresetBar(ctx)
  LFOPanels.drawUIMode(ctx)

  -- POLYGON
  Widgets.drawSectionSep(ctx, dl, "POLYGON")
  LFOPanels.drawPolygonPanel(ctx)
  LFOPanels.drawRadarPanel(ctx)

  -- CURVE (Advanced only) — fade in/out
  do
    local a, vis = LFOPanels.sectionAlpha("lfo_curve", LFOPanels.shouldShowCurve())
    if vis then
      LFOPanels.setDrawAlpha(a)
      if a < 1.0 then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), a) end
      Widgets.drawSectionSep(ctx, dl, "CURVE", a)
      LFOPanels.drawCurvePanel(ctx)
      if a < 1.0 then reaper.ImGui_PopStyleVar(ctx) end
      LFOPanels.setDrawAlpha(1.0)
    end
  end

  -- SEGMENT SHAPE
  Widgets.drawSectionSep(ctx, dl, "SEGMENT SHAPE")
  LFOPanels.drawShapePanel(ctx)

  -- PREVIEW
  Widgets.drawSectionSep(ctx, dl, "PREVIEW")
  LFOPanels.drawPreviewPanel(ctx)

  -- AMPLITUDE
  Widgets.drawSectionSep(ctx, dl, "AMPLITUDE")
  LFOPanels.drawAmplitudePanel(ctx)

  -- AMP RANGE
  Widgets.drawSectionSep(ctx, dl, "AMP RANGE")
  LFOPanels.drawAmpRangePanel(ctx)

  -- CYCLES
  Widgets.drawSectionSep(ctx, dl, "CYCLES")
  LFOPanels.drawCyclesPanel(ctx)

  -- QUANTIZE / PRECISION (Advanced) — fade in/out
  do
    local a, vis = LFOPanels.sectionAlpha("lfo_advanced", LFOPanels.isAdvanced())
    if vis then
      LFOPanels.setDrawAlpha(a)
      if a < 1.0 then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), a) end
      Widgets.drawSectionSep(ctx, dl, "QUANTIZE", a)
      LFOPanels.drawQuantizePanel(ctx)
      Widgets.drawSectionSep(ctx, dl, "PRECISION", a)
      LFOPanels.drawPrecisionPanel(ctx)
      if a < 1.0 then reaper.ImGui_PopStyleVar(ctx) end
      LFOPanels.setDrawAlpha(1.0)
    end
  end

  -- INSERT & STATUS
  reaper.ImGui_Dummy(ctx, 1, 1)
  Widgets.drawSectionSep(ctx, dl, "INSERT")
  LFOPanels.drawInsertPanel(ctx, dl, ctx_info)
  reaper.ImGui_Dummy(ctx, 1, 2)
  LFOPanels.drawContextPanel(ctx, dl, ctx_info)
  reaper.ImGui_Dummy(ctx, 1, 2)
  LFOPanels.drawStatusBar(ctx, dl)
end

-- ── STANDALONE LOGIC (runs only when launched standalone) ─────
local function standalone_main()
  local ctx = reaper.ImGui_CreateContext(script_name)
  LFOPresets.init()
  LFOPanels.resetSnapshot()
  Logger.ok("LFO Standalone: Select envelope & time selection")

  local SW = require("StandaloneWindow")
  SW.run(ctx, script_name, {
    win_w         = LFOConfig.WIN_W,
    win_h         = LFOConfig.WIN_H,
    win_min_w     = LFOConfig.WIN_MIN_W,
    win_min_h     = LFOConfig.WIN_MIN_H,
    win_max_w     = LFOConfig.WIN_MAX_W,
    win_max_h     = LFOConfig.WIN_MAX_H,
    ext_state_key = "ReaCurve_LFO",
  }, LFO_Tool.drawUI, {
    child_id = "##lfo_content",
  })
end

-- Detection: if SLK_HUB_IN_USE is not defined, launch standalone mode
if not SLK_HUB_IN_USE then
    standalone_main()
end

return LFO_Tool
