-- @description ReaCurve - RAND (Random Envelope Generator)
-- @author sailok
-- @version 1.0.0
-- @about
--   Procedurally generates random automation with configurable
--   ranges, amplitude scaling and offset parameters.
--   Can be run standalone or as part of the ReaCurve Suite.
--
--   Requires: ReaImGui extension, SWS/S&M extension, js_ReaScriptAPI
--   Install the "ReaCurve Suite" package to get all dependencies.
-- @link https://github.com/sailok-audio/ReaCurve

-- ============================================================
--   ReaCurve_RAND.lua
--   Can be launched standalone or imported as a module in the Hub
-- ============================================================
local script_name = "Random Envelope Generator"
local RAND_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]
                       :match('^.+[/\\]')
                       :gsub('\\', '/')

package.path = _script_path .. "lib/RAND/?.lua;"
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

local RANDConfig      = require("RANDConfig")
local RANDState       = require("RANDState")
local RANDWrite       = require("RANDWrite")
local Generator       = require("Generator")
local Logger          = require("Logger")
local Theme           = require("Theme")
local ReaperUtils     = require("ReaperUtils")
local RANDPanel       = require("RANDPanel")
local Widgets         = require("Widgets")

math.randomseed(os.time())

-- ── MAIN DRAW FUNCTION (called by Hub or Standalone) ──────────
function RAND_Tool.drawUI(ctx)
  local T   = Theme
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local S   = RANDState
  local cfg = RANDConfig

  local ctx_info = ReaperUtils.getContextInfo()

  -- Build params and refresh preview
  local range  = cfg.AMP_RANGES[S.amp_range] or cfg.AMP_RANGES[1]

  -- Amplitude scale + offset modify the effective range:
  --   amp_scale (0..1): reduces the half-range from center
  --   amp_offset(-1..1): shifts the center (±1 = ±100% of full range)
  local amp_scale  = S.amp_scale  or 1.0
  local amp_offset = S.amp_offset or 0.0
  local center     = (range.lo + range.hi) * 0.5
  local half       = (range.hi - range.lo) * 0.5 * amp_scale
  local shift      = amp_offset * 0.5   -- [0,1] space: 0.5 = 50% of full bipolar range
  local eff_lo     = math.max(0, math.min(1, center - half + shift))
  local eff_hi     = math.max(0, math.min(1, center + half + shift))

  local params = {
    seed        = S.seed,
    shape_seed  = S.shape_seed,
    n_points    = S.num_points,
    pts_per_div = S.pts_per_div,
    shape       = S.shape,
    tension     = S.tension,
    amp_lo      = eff_lo,
    amp_hi      = eff_hi,
    amp_free    = S.amp_free,
    quant_steps = S.quant_steps,
  }
  RANDWrite.refreshPreview(S, params)
  if S.shape == 5 then
    RANDWrite.rebuildPreviewCurve(S, params)
  end

  -- ══ MODE ══════════════════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "MODE")
  RANDPanel.drawModePanel(ctx)

  -- ══ PREVIEW ════════════════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "PREVIEW")
  do
    local aw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local gh     = math.max(cfg.GRAPH_HEIGHT, 160)
    local gx, gy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, "##preview_rand", aw, gh)
    RANDPanel.drawPreviewGraph(ctx, dl, gx, gy, aw, gh,
      eff_lo, eff_hi, S.amp_free, S.quant_steps)
  end

  -- ══ GENERATION ════════════════════════════════════════════════
  reaper.ImGui_Dummy(ctx, 1, 2)
  Widgets.drawSectionSep(ctx, dl, "GENERATION")
  RANDPanel.drawGenerationPanel(ctx)
  reaper.ImGui_Dummy(ctx, 1, 4)
  RANDPanel.drawNewSeedPanel(ctx)

  -- ══ SHAPE ══════════════════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "SHAPE")
  RANDPanel.drawShapePanel(ctx)

  -- ══ AMPLITUDE RANGE ════════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "AMPLITUDE RANGE")
  RANDPanel.drawAmplitudeRangePanel(ctx)

  -- ══ QUANTIZED AMPLITUDE ════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "QUANTIZED AMPLITUDE")
  RANDPanel.drawAmplitudeTypePanel(ctx)

  -- ══ INSERT ═════════════════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "INSERT")
  RANDPanel.drawInsertPanel(ctx, dl, ctx_info)

  RANDPanel.drawContextPanel(ctx, dl, ctx_info)
  RANDPanel.drawStatusBar(ctx, dl)
end

-- ── STANDALONE LOGIC (runs only when launched standalone) ─────
local function standalone_main()
  local ctx = reaper.ImGui_CreateContext(script_name)
  Logger.ok("Select envelope lane and time selection")

  local SW = require("StandaloneWindow")
  SW.run(ctx, script_name, {
    win_w         = RANDConfig.WIN_W,
    win_h         = RANDConfig.WIN_H,
    win_min_w     = RANDConfig.WIN_MIN_W,
    win_min_h     = RANDConfig.WIN_MIN_H,
    win_max_w     = RANDConfig.WIN_MAX_W,
    win_max_h     = RANDConfig.WIN_MAX_H,
    ext_state_key = "ReaCurve_RAND",
  }, RAND_Tool.drawUI, {
    child_id = "##rand_content",
  })
end

-- Detection: if SLK_HUB_IN_USE is not defined, launch standalone mode
if not SLK_HUB_IN_USE then
  standalone_main()
end

return RAND_Tool
