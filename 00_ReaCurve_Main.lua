-- @description ReaCurve Suite — MORPH · LFO · RAND · SCULPT
-- @author sailok
-- @version 1.0.0
-- @provides
--   [nomain] lib/CommonFunction/EnvConvert.lua
--   [nomain] lib/CommonFunction/EnvWriter.lua
--   [nomain] lib/CommonFunction/EnvelopeUtils.lua
--   [nomain] lib/CommonFunction/Generator.lua
--   [nomain] lib/CommonFunction/GridUtils.lua
--   [nomain] lib/CommonFunction/Logger.lua
--   [nomain] lib/CommonFunction/ReaperUtils.lua
--   [nomain] lib/CommonFunction/ScaleConverter.lua
--   [nomain] lib/CommonFunction/UI/Anim.lua
--   [nomain] lib/CommonFunction/UI/Slider.lua
--   [nomain] lib/CommonFunction/UI/StandaloneWindow.lua
--   [nomain] lib/CommonFunction/UI/Theme.lua
--   [nomain] lib/CommonFunction/UI/TitleBar.lua
--   [nomain] lib/CommonFunction/UI/Toggle.lua
--   [nomain] lib/CommonFunction/UI/Widgets.lua
--   [nomain] lib/LFO/LFOConfig.lua
--   [nomain] lib/LFO/LFOGeometry.lua
--   [nomain] lib/LFO/LFOPresets.lua
--   [nomain] lib/LFO/LFOState.lua
--   [nomain] lib/LFO/LFOWrite.lua
--   [nomain] lib/MORPH/MORPHCapture.lua
--   [nomain] lib/MORPH/MORPHConfig.lua
--   [nomain] lib/MORPH/MORPHEngine.lua
--   [nomain] lib/MORPH/MORPHState.lua
--   [nomain] lib/MORPH/MORPHWrite.lua
--   [nomain] lib/RAND/RANDConfig.lua
--   [nomain] lib/RAND/RANDState.lua
--   [nomain] lib/RAND/RANDWrite.lua
--   [nomain] lib/SCULPT/SCULPTConfig.lua
--   [nomain] lib/SCULPT/SCULPTEngine.lua
--   [nomain] lib/SCULPT/SCULPTState.lua
--   [nomain] lib/SCULPT/SCULPTWrite.lua
--   [nomain] lib/UI/LFOPanel.lua
--   [nomain] lib/UI/MORPHPanel.lua
--   [nomain] lib/UI/RANDPanel.lua
--   [nomain] lib/UI/SCULPTPanel.lua
--   [nomain] LFOPresets/init.lua
--   [nomain] LFOPresets/glitch.lua
--   [nomain] LFOPresets/classics/adsr.lua
--   [nomain] LFOPresets/classics/sawtooth_down.lua
--   [nomain] LFOPresets/classics/sawtooth_up.lua
--   [nomain] LFOPresets/classics/sh.lua
--   [nomain] LFOPresets/classics/sine.lua
--   [nomain] LFOPresets/classics/sinish.lua
--   [nomain] LFOPresets/classics/square.lua
--   [nomain] LFOPresets/classics/triangle.lua
--   [main] ReaCurve_LFO.lua
--   [main] ReaCurve_MORPH.lua
--   [main] ReaCurve_RAND.lua
--   [main] ReaCurve_SCULPT.lua
--   [main] ReaCurve_ResetExtState.lua
-- @about
--   ReaCurve is a suite of four envelope tools for REAPER:
--   - MORPH : Morphs between two captured envelope snapshots
--   - LFO   : Polygon LFO generator with presets
--   - RAND  : Random envelope generator
--   - SCULPT: Envelope manipulation (skew, tilt, compress, swing)
--
--   Requires: ReaImGui extension, SWS/S&M extension, js_ReaScriptAPI
-- @link https://github.com/sailok-audio/ReaCurve

-- ============================================================
--   ReaCurve_MAIN.lua  v2.1
--   ReaCurve Tools Hub — four tools in a single tabbed window.
--
--   Tab order: RAND | LFO | SCULPT | MORPH
--
--   All tools share one ImGui context.
--   Each tool exposes drawUI(ctx) — same pattern as ReaCurve_LFO.
--   MORPHCapture.pollCapture() runs every frame (global morpher input).
-- ============================================================

local script_name = "ReaCurve Tools"

-- ── Dependency check ──────────────────────────────────────────
do
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
      "ReaCurve requires the following missing package(s):\n\n"
      .. table.concat(missing, "\n")
      .. "\n\nInstall them via ReaPack and restart REAPER.",
      "ReaCurve — Missing dependencies", 0)
    return
  end
end

-- CRITICAL FLAG: must be defined before any require() of the tools
SLK_HUB_IN_USE = true

local _script_path = ({reaper.get_action_context()})[2]
                       :match('^.+[/\\]')
                       :gsub('\\', '/')

package.path = _script_path .. "?.lua;"
            .. _script_path .. "lib/LFO/?.lua;"
            .. _script_path .. "lib/RAND/?.lua;"
            .. _script_path .. "lib/SCULPT/?.lua;"
            .. _script_path .. "lib/MORPH/?.lua;"
            .. _script_path .. "lib/UI/?.lua;"
            .. _script_path .. "lib/CommonFunction/?.lua;"
            .. _script_path .. "lib/CommonFunction/UI/?.lua;"
            .. package.path

-- ── Load tool modules ─────────────────────────────────────────
local LFO_Tool   = require("ReaCurve_LFO")
local RAND_Tool  = require("ReaCurve_RAND")
local SCULPT_Tool   = require("ReaCurve_SCULPT")
local MORPH_Tool = require("ReaCurve_MORPH")

-- ── Hub shared modules ────────────────────────────────────────
local Theme    = require("Theme")
local Logger   = require("Logger")
local ReaperUtils = require("ReaperUtils")
local LFOPresets  = require("LFOPresets")
local Capture     = require("MORPHCapture")
local TitleBar    = require("TitleBar")

local T       = Theme
local TITLE_H = TitleBar.TITLE_H

math.randomseed(os.time())

-- ── Window geometry ───────────────────────────────────────────
local WIN_W     = 360
local WIN_H     = 980
local WIN_MIN_W = 360
local WIN_MIN_H = 500
local WIN_MAX_W = 900
local WIN_MAX_H = 1800

local _suppress_scrollbar_frames = 0

-- ── Runtime ───────────────────────────────────────────────────
local ctx        = nil
local active_tab = 1
local COND_FIRST_USE_EVER

-- Save size before collapse to restore on expand
local prev_win_w   = WIN_W
local prev_win_h   = WIN_H
local restore_size = false

-- ── Titlebar state (shared with TitleBar.draw) ────────────────
-- dock_enabled: ExtState "1" = enabled, "0" or absent = disabled  (default: disabled)
local hub_state = {
  collapsed    = false,
  dock_enabled = reaper.GetExtState("ReaCurve_MAIN", "dock_en") == "1",
  hover_time   = nil,
}

-- ── Transition: fade-in over 0.22s after switch, starts at 0.30 ──
local FADE_DUR    = 0.22
local FADE_START  = 0.30   -- initial alpha after switch (avoids black frame)
local _fade_alpha = 1.0
local _fade_timer = 0.0
local _fading     = false
local _last_time  = 0.0

-- Cubic ease-in-out: slow start, fast middle, slow end
local function easeInOutCubic(t)
  if t < 0.5 then return 4*t*t*t
  else local u=t-1; return 1+4*u*u*u end
end

-- ── Tab definitions (order: RAND, LFO, SCULPT, MORPH) ────────────
local TABS = {
  { id = "rand",  label = "RAND",  col_base = T.C_MRF_BASE, col_hov = T.C_MRF_HOV, col_sel = T.C_MRF_SEL },
  { id = "lfo",   label = "LFO",   col_base = T.C_AI2_BASE, col_hov = T.C_AI2_HOV, col_sel = T.C_AI2_SEL },
  { id = "sculpt",   label = "SCULPT",   col_base = T.C_AI1_BASE, col_hov = T.C_AI1_HOV, col_sel = T.C_AI1_SEL },
  { id = "morph", label = "MORPH", col_base = "#E8844A",    col_hov = "#F09A62",    col_sel = "#6B3010"   },
}

-- ── Per-tab window heights ────────────────────────────────────
-- Default height for each tab (RAND, LFO, SCULPT, MORPH). Adjust as needed.
local TAB_HEIGHTS = { 896, 997, 908, 764 }
-- Tracks the current saved height per tab; updated when the user resizes manually.
local tab_saved_h = { TAB_HEIGHTS[1], TAB_HEIGHTS[2], TAB_HEIGHTS[3], TAB_HEIGHTS[4] }
local _tab_resize = false   -- triggers a forced resize on the next frame after a tab switch

-- ── Geometry persistence ──────────────────────────────────────
local EXT_KEY = "ReaCurve_MAIN"

local function loadHubGeometry()
  local w = tonumber(reaper.GetExtState(EXT_KEY, "win_w"))
  if w and w >= WIN_MIN_W then WIN_W = w ; prev_win_w = w end
  for i = 1, #TABS do
    local h = tonumber(reaper.GetExtState(EXT_KEY, "tab_h_" .. i))
    if h and h >= WIN_MIN_H then tab_saved_h[i] = h end
  end
end

-- ── Custom tab bar ────────────────────────────────────────────
local function drawTabBar()
  -- dl fetched from the current context → clip rect of the child, not parent
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local aw  = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local n   = #TABS
  local gap = 2
  local tab_h = 22
  local fh    = reaper.ImGui_GetTextLineHeight(ctx)
  local rnd   = 5

  local tab_w   = math.floor((aw - gap * (n - 1)) / n)
  local total_w = n * tab_w + (n - 1) * gap

  local start_x, start_y = reaper.ImGui_GetCursorScreenPos(ctx)
  local shelf_y = start_y + tab_h
  local tab_sx  = {}   -- screen positions of each tab (to draw shelf afterwards)

  for i, tab in ipairs(TABS) do
    if i > 1 then reaper.ImGui_SameLine(ctx, 0, gap) end

    local sx, sy  = reaper.ImGui_GetCursorScreenPos(ctx)
    tab_sx[i]     = sx
    local is_act  = (i == active_tab)

    local pressed = reaper.ImGui_InvisibleButton(ctx, "##tab_"..tab.id, tab_w, tab_h)
    local hov     = reaper.ImGui_IsItemHovered(ctx)

    if pressed and i ~= active_tab then
      _suppress_scrollbar_frames = 3
      active_tab  = i
      _fade_alpha = FADE_START
      _fade_timer = 0.0
      _fading     = true
      _tab_resize = true   -- resize window to the new tab's saved height next frame
    end

    local top_y = is_act and sy or (sy + 2)
    local bot_y = is_act and (shelf_y + 1) or shelf_y

    local bg_col, txt_col, brd_col, brd_w
    if is_act then
      bg_col  = T.hx(T.C_BG_MAIN, 1.0)
      txt_col = T.hx(tab.col_base, 1.0)
      brd_col = T.hx(tab.col_base, 0.80)
      brd_w   = 2.0
    elseif hov then
      bg_col  = T.hx(T.C_BG_PANEL, 0.7)
      txt_col = T.hx(tab.col_hov, 0.95)
      brd_col = T.hx(T.C_BORDER, 0.38)
      brd_w   = 1.0
    else
      bg_col  = T.hx(T.C_BG_PANEL, 0.25)
      txt_col = T.hx("#FFFFFF", 0.58)
      brd_col = T.hx(T.C_BORDER, 0.22)
      brd_w   = 1.0
    end

    reaper.ImGui_DrawList_AddRectFilled(dl, sx, top_y,     sx+tab_w, top_y+rnd*2, bg_col, rnd)
    reaper.ImGui_DrawList_AddRectFilled(dl, sx, top_y+rnd, sx+tab_w, bot_y,       bg_col)

    reaper.ImGui_DrawList_AddLine(dl, sx,       top_y, sx+tab_w, top_y,   brd_col, brd_w)
    reaper.ImGui_DrawList_AddLine(dl, sx,       top_y, sx,       shelf_y, brd_col, brd_w)
    reaper.ImGui_DrawList_AddLine(dl, sx+tab_w, top_y, sx+tab_w, shelf_y, brd_col, brd_w)

    local lw = reaper.ImGui_CalcTextSize(ctx, tab.label)
    local ty = sy + (tab_h - fh) * 0.5
    reaper.ImGui_DrawList_AddText(dl, sx + (tab_w - lw) * 0.5, ty, txt_col, tab.label)
  end

  -- Shelf line drawn AFTER fills → visible on top of inactive tabs
  -- Two segments that skip the active tab (opening to content)
  local shelf_col  = T.hx(TABS[active_tab].col_base, 0.80)
  local act_x      = tab_sx[active_tab]
  local act_right  = act_x + tab_w
  if act_x > start_x then
    reaper.ImGui_DrawList_AddLine(dl, start_x, shelf_y, act_x,               shelf_y, shelf_col, 2.0)
  end
  if act_right < start_x + total_w then
    reaper.ImGui_DrawList_AddLine(dl, act_right, shelf_y, start_x + total_w, shelf_y, shelf_col, 2.0)
  end

  reaper.ImGui_Dummy(ctx, aw, 1)
  return shelf_y, start_x, total_w
end

-- ── Tab dispatch ──────────────────────────────────────────────
local TAB_DRAW = {
  function() RAND_Tool.drawUI(ctx)  end,  -- 1  RAND
  function() LFO_Tool.drawUI(ctx)   end,  -- 2  LFO
  function() SCULPT_Tool.drawUI(ctx)   end,  -- 3  SCULPT
  function() MORPH_Tool.drawUI(ctx) end,  -- 4  MORPH
}

-- ── Active panel content (with fade) ──────────────────────────
local function drawPanelContent()
  local now = reaper.time_precise()
  local dt  = math.max(0, math.min(0.1, now - _last_time))
  _last_time = now

  -- Pre-calculated geometry identical to drawTabBar (same formulas, same ctx)
  local aw      = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local n, gap  = #TABS, 2
  local tab_w_p = math.floor((aw - gap * (n - 1)) / n)
  local total_w = n * tab_w_p + (n - 1) * gap
  local bx, by  = reaper.ImGui_GetCursorScreenPos(ctx)
  local shelf_y = by + 22   -- tab_h = 22
  local tot_h   = select(2, reaper.ImGui_GetContentRegionAvail(ctx))

  -- Only the bottom border is drawn: shelf is in drawTabBar, left/right removed.
  local dl    = reaper.ImGui_GetWindowDrawList(ctx)
  local col   = T.hx(TABS[active_tab].col_base, 0.80)
  local bot_y = by + tot_h
  reaper.ImGui_DrawList_AddLine(dl, bx, bot_y, bx + total_w, bot_y, col, 2.0)

  -- Tabs drawn on top (their fills cover the upper border line)
  drawTabBar()

  -- Cursor placed directly under the shelf, without item-spacing gap
  reaper.ImGui_SetCursorScreenPos(ctx, bx, shelf_y + 1)

  -- Fade-in: FADE_START → 1.0 with cubic ease-in-out
  if _fading then
    _fade_timer = _fade_timer + dt
    local t     = math.min(1.0, _fade_timer / FADE_DUR)
    _fade_alpha = FADE_START + (1.0 - FADE_START) * easeInOutCubic(t)
    if t >= 1.0 then _fade_alpha = 1.0 ; _fading = false end
  end

  if _fade_alpha < 1.0 then
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), _fade_alpha)
  end

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(), 4, 4)
  local child_flags = 0
  
  if _tab_resize or _suppress_scrollbar_frames > 0 then
    child_flags = child_flags | reaper.ImGui_WindowFlags_NoScrollbar()
    
    if _suppress_scrollbar_frames > 0 then
      _suppress_scrollbar_frames = _suppress_scrollbar_frames - 1
    end
  end
  
  if reaper.ImGui_BeginChild(ctx, "##tool_pane", total_w, 0, 0, child_flags) then
    local fn = TAB_DRAW[active_tab]
    if fn then fn() end
    reaper.ImGui_EndChild(ctx)
  end
  
  reaper.ImGui_PopStyleVar(ctx)

  if _fade_alpha < 1.0 then
    reaper.ImGui_PopStyleVar(ctx)
  end
end

-- ── ImGui loop ────────────────────────────────────────────────
local function init()
  ctx        = reaper.ImGui_CreateContext(script_name)
  _last_time = reaper.time_precise()
  COND_FIRST_USE_EVER = reaper.ImGui_Cond_FirstUseEver()
  loadHubGeometry()    -- restore persisted per-tab sizes
  _tab_resize = true   -- apply loaded sizes on first frame
  LFOPresets.init()
  Logger.ok("Hub ready — select a tab to start")
end

local function loop()
  if reaper.ImGui_IsValid and not reaper.ImGui_IsValid(ctx) then return end

  Capture.pollCapture()

  local win_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                  | reaper.ImGui_WindowFlags_NoCollapse()
                  | reaper.ImGui_WindowFlags_NoScrollbar()
                  | reaper.ImGui_WindowFlags_NoScrollWithMouse()
  if not hub_state.dock_enabled and reaper.ImGui_WindowFlags_NoDocking then
    win_flags = win_flags | reaper.ImGui_WindowFlags_NoDocking()
  end

  local min_h = hub_state.collapsed and (TITLE_H + 14) or WIN_MIN_H
  local max_h = hub_state.collapsed and (TITLE_H + 14) or WIN_MAX_H

  local cmin_w, cmin_h, cmax_w, cmax_h = WIN_MIN_W, min_h, WIN_MAX_W, max_h
  if restore_size or _tab_resize then
    -- Force exact target size for this frame only (min=max=target).
    -- Both tab switches and expand-from-collapse use the active tab's saved height.
    local target_h = tab_saved_h[active_tab]
    reaper.ImGui_SetNextWindowSize(ctx, prev_win_w, target_h, reaper.ImGui_Cond_Always())
    cmin_w, cmin_h, cmax_w, cmax_h = prev_win_w, target_h, prev_win_w, target_h
    restore_size = false
    _tab_resize  = false
  else
    reaper.ImGui_SetNextWindowSize(ctx, WIN_W, WIN_H, COND_FIRST_USE_EVER)
  end
  if reaper.ImGui_SetNextWindowSizeConstraints then
    reaper.ImGui_SetNextWindowSizeConstraints(ctx, cmin_w, cmin_h, cmax_w, cmax_h)
  end

  -- ── Global window style ───────────────────────────────────
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),
    T.hx(T.C_BG_MAIN))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
    T.hx(T.C_BORDER, 0.45))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGrip(),
    T.hx(T.C_BORDER, 0.20))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGripHovered(),
    T.hx(T.C_CFG_SEL, 0.55))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGripActive(),
    T.hx(T.C_CFG_SEL, 0.90))
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1.0)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),    8, 6)

  local visible, open = reaper.ImGui_Begin(ctx, script_name, true, win_flags)

  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx,   2)

  if visible then
    -- Save current size when not collapsed (restored on expand + persisted across sessions)
    if not hub_state.collapsed then
      local cw, ch = reaper.ImGui_GetWindowSize(ctx)
      if cw and ch then
        if cw ~= prev_win_w then
          prev_win_w = cw
          reaper.SetExtState(EXT_KEY, "win_w", tostring(cw), true)
        end
        if ch ~= tab_saved_h[active_tab] then
          tab_saved_h[active_tab] = ch
          reaper.SetExtState(EXT_KEY, "tab_h_" .. active_tab, tostring(ch), true)
        end
        prev_win_h = ch
      end
    end

    local dl = reaper.ImGui_GetWindowDrawList(ctx)

    -- Custom titlebar via shared module
    local want_close, want_dock, want_collapse = TitleBar.draw(ctx, dl, script_name, hub_state)

    if want_close then open = false end
    if want_dock  then
      hub_state.dock_enabled = not hub_state.dock_enabled
      reaper.SetExtState("ReaCurve_MAIN", "dock_en",
        hub_state.dock_enabled and "1" or "0", true)
    end
    if want_collapse then
      if hub_state.collapsed then restore_size = true end  -- expanding → restore size
      hub_state.collapsed = not hub_state.collapsed
    end

    -- Scrollable content in BeginChild (height = remaining available)
    if not hub_state.collapsed then
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 6, 4)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(),
        T.hx(T.C_BG_MAIN))
      local no_scroll = reaper.ImGui_WindowFlags_NoScrollbar()
                      | reaper.ImGui_WindowFlags_NoScrollWithMouse()
      if reaper.ImGui_BeginChild(ctx, "##hub_content", 0, 0, 0, no_scroll) then
        drawPanelContent()
        reaper.ImGui_EndChild(ctx)
      end
      reaper.ImGui_PopStyleColor(ctx, 1)
      reaper.ImGui_PopStyleVar(ctx, 1)
    end

    reaper.ImGui_End(ctx)
  end

  if open then reaper.defer(loop) end
end

init()
reaper.defer(loop)
