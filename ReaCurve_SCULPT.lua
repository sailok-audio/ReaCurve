-- @description ReaCurve - SCULPT (Envelope Manipulation Tool)
-- @author sailok
-- @version 1.0.0
-- @about
--   Applies transformations to existing envelopes: skew, tilt,
--   compress, swing, amplitude scaling and timing adjustments.
--   Can be run standalone or as part of the ReaCurve Suite.
--
--   Requires: ReaImGui extension, SWS/S&M extension, js_ReaScriptAPI
--   Install the "ReaCurve Suite" package to get all dependencies.
-- @link https://github.com/sailok-audio/ReaCurve

-- ============================================================
--   ReaCurve_SCULPT.lua
--   Can be launched standalone or imported as a module in the Hub
--
--   Sections:
--     OPERATIONS | SHAPE | RANGE
--     AMPLITUDE  (baseline · amp scale · amp skew · tilt+curve)
--     TIMING     (skew + pivot · h compress + anchor)
--     SWING      (swing slider + reset)
--     CONTEXT / STATUS
-- ============================================================
local script_name = "SCULPT"
local Sculpt_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]
                       :match('^.+[/\\]')
                       :gsub('\\', '/')

package.path = _script_path .. "lib/SCULPT/?.lua;"
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

local Logic   = require("SCULPTWrite")
local S       = require("SCULPTState")
local Panels  = require("SCULPTPanel")
local Logger  = require("Logger")
local Theme   = require("Theme")

math.randomseed(os.time())

local WIN_W     = 420
local WIN_H     = 980
local WIN_MIN_W = 320
local WIN_MIN_H = 560
local WIN_MAX_W = 900
local WIN_MAX_H = 1800

-- ── MAIN DRAW FUNCTION (called by Hub or Standalone) ──────────
function Sculpt_Tool.drawUI(ctx)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local env = reaper.GetSelectedEnvelope(0)

  Logic.updateReferenceState(env)
  Panels.onNewRef(S.ref_pts ~= nil)

  -- ══ OPERATIONS (includes range selector) ═════════════════
  Panels.drawSectionSep(ctx, dl, "OPERATIONS")
  Panels.drawOperationsPanel(ctx)

  -- ══ SHAPE ════════════════════════════════════════════════
  reaper.ImGui_Dummy(ctx, 1, 4)
  Panels.drawSectionSep(ctx, dl, "SHAPE")
  Panels.drawShapePanel(ctx, env)

  -- ══ AMPLITUDE MODIFIERS ═══════════════════════════════════
  Panels.drawSectionSep(ctx, dl, "AMPLITUDE")
  Panels.drawAmplitudeSection(ctx, env)

  -- ══ TIMING (includes swing first) ═════════════════════════
  reaper.ImGui_Dummy(ctx, 1, 4)
  Panels.drawSectionSep(ctx, dl, "TIMING")
  Panels.drawTimingSection(ctx, env)

  -- ══ CONTEXT ═══════════════════════════════════════════════
  reaper.ImGui_Dummy(ctx, 1, 4)
  Panels.drawContextPanel(ctx, dl)

  -- ══ STATUS BAR ════════════════════════════════════════════
  reaper.ImGui_Dummy(ctx, 1, 2)
  Panels.drawStatusBar(ctx, dl)
end

-- ── STANDALONE LOGIC (runs only when launched standalone) ─────
local function standalone_main()
  local ctx = reaper.ImGui_CreateContext(script_name)
  Logger.ok("Select envelope points or a time selection to start")

  local SW = require("StandaloneWindow")
  SW.run(ctx, script_name, {
    win_w         = WIN_W,
    win_h         = WIN_H,
    win_min_w     = WIN_MIN_W,
    win_min_h     = WIN_MIN_H,
    win_max_w     = WIN_MAX_W,
    win_max_h     = WIN_MAX_H,
    ext_state_key = "ReaCurve_SCULPT",
  }, Sculpt_Tool.drawUI, {
    child_id = "##env_content",
  })
end

-- Detection: if SLK_HUB_IN_USE is not defined, launch standalone mode
if not SLK_HUB_IN_USE then
  standalone_main()
end

return Sculpt_Tool