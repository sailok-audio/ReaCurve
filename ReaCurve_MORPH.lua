-- @description ReaCurve - MORPH (Envelope Snapshot Morpher)
-- @author sailok
-- @version 1.0.0
-- @about
--   Morphs smoothly between two captured envelope snapshots.
--   Includes precision presets and point-reduction algorithms.
--   Can be run standalone or as part of the ReaCurve Suite.
--
--   Requires: ReaImGui extension, SWS/S&M extension, js_ReaScriptAPI
--   Install the "ReaCurve Suite" package to get all dependencies.
-- @link https://github.com/sailok-audio/ReaCurve

-- ============================================================
--   ReaCurve_MORPH.lua  v6.3
--   Can be launched standalone or imported as a module in the Hub
--   Business logic lives in MORPHCapture, MORPHWrite, MORPHEngine.
-- ============================================================
local script_name = "MORPHER"
local Morph_Tool = {}

local _script_path = ({reaper.get_action_context()})[2]
                       :match('^.+[/\\]')
                       :gsub('\\', '/')

package.path = _script_path .. "lib/MORPH/?.lua;"
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

local Config      = require("MORPHConfig")
local State       = require("MORPHState")
local Logger      = require("Logger")
local Theme       = require("Theme")
local Capture     = require("MORPHCapture")
local MorphEngine = require("MORPHEngine")
local ReaperUtils = require("ReaperUtils")
local Panels      = require("MORPHPanel")
local Widgets     = require("Widgets")

local WF_NOSCROLL = 8  -- ImGui_WindowFlags_NoScrollbar

-- ── Morph slider state (persistent between frames) ────────────
local _morph_drag_start  = nil   -- {mx, val} anchor for Ctrl/Shift precision
local _morph_pct_editing = false -- true when the InputText % is open
local _morph_pct_buf     = ""    -- input buffer
local _morph_pct_frame   = 0    -- frame counter since input was opened

-- ── Centered text helper ──────────────────────────────────────
local function centeredText(ctx, label)
  local aw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local tw = reaper.ImGui_CalcTextSize(ctx, label)
  reaper.ImGui_SetCursorPosX(ctx, reaper.ImGui_GetCursorPosX(ctx) + (aw - tw) * 0.5)
  reaper.ImGui_Text(ctx, label)
end

-- ── MAIN DRAW FUNCTION (called by Hub or Standalone) ──────────
function Morph_Tool.drawUI(ctx)
  local T  = Theme
  local dl = reaper.ImGui_GetWindowDrawList(ctx)

  -- Refresh frozen-sample display cache before rendering source slots
  Capture.refreshCache()

  -- Resolve context info once per frame
  local ctx_info = ReaperUtils.getContextInfo()

  -- ══ SOURCES ══════════════════════════════════════════════════
  Widgets.drawSectionSep(ctx, dl, "SOURCES")

  do
    local avw    = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local half_w = math.max(4, math.floor((avw - 4) / 2))
    local MINI_H = 72
    local SLOT_H = 158

    -- Source 1
    if reaper.ImGui_BeginChild(ctx, "##col_src1", half_w, SLOT_H, 0, WF_NOSCROLL) then
      local cdl = reaper.ImGui_GetWindowDrawList(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI1_HOV, 1))
      centeredText(ctx, "SOURCE 1")
      reaper.ImGui_PopStyleColor(ctx)
      Panels.drawSourceSlot(ctx, cdl, 1)
      local ax, ay = reaper.ImGui_GetCursorScreenPos(ctx)
      local aw2    = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      reaper.ImGui_InvisibleButton(ctx, "##mg1", aw2, MINI_H)
      Panels.drawSlotMiniGraph(cdl, ax, ay, aw2, MINI_H, 1)
      if State.slot1_type == "ai" and State.ai1 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI1_SEL))
        reaper.ImGui_Text(ctx, string.format("  TRK_%d · AI #%d  @%.2fs",
          State.ai1.track_idx+1, State.ai1.ai_idx+1, State.ai1.pos))
        reaper.ImGui_PopStyleColor(ctx)
      elseif State.slot1_type == "sel" and State.sel1 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI1_SEL))
        local tn = State.sel1.track_num and ("TRK_"..State.sel1.track_num) or "?"
        local ts = State.sel1.t0_abs and string.format("@%.2fs", State.sel1.t0_abs) or ""
        reaper.ImGui_Text(ctx, string.format("  %s · ENV · %s", tn, ts))
        reaper.ImGui_PopStyleColor(ctx)
      else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI1_SEL))
        reaper.ImGui_Text(ctx, "  no data")
        reaper.ImGui_PopStyleColor(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end

    reaper.ImGui_SameLine(ctx, 0, 4)

    -- Source 2
    if reaper.ImGui_BeginChild(ctx, "##col_src2", half_w, SLOT_H, 0, WF_NOSCROLL) then
      local cdl = reaper.ImGui_GetWindowDrawList(ctx)
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI2_HOV, 1))
      centeredText(ctx, "SOURCE 2")
      reaper.ImGui_PopStyleColor(ctx)
      Panels.drawSourceSlot(ctx, cdl, 2)
      local ax, ay = reaper.ImGui_GetCursorScreenPos(ctx)
      local aw2    = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
      reaper.ImGui_InvisibleButton(ctx, "##mg2", aw2, MINI_H)
      Panels.drawSlotMiniGraph(cdl, ax, ay, aw2, MINI_H, 2)
      if State.slot2_type == "ai" and State.ai2 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI2_SEL))
        reaper.ImGui_Text(ctx, string.format("  TRK_%d · AI #%d  @%.2fs",
          State.ai2.track_idx+1, State.ai2.ai_idx+1, State.ai2.pos))
        reaper.ImGui_PopStyleColor(ctx)
      elseif State.slot2_type == "sel" and State.sel2 then
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI2_SEL))
        local tn = State.sel2.track_num and ("TRK_"..State.sel2.track_num) or "?"
        local ts = State.sel2.t0_abs and string.format("@%.2fs", State.sel2.t0_abs) or ""
        reaper.ImGui_Text(ctx, string.format("  %s · ENV · %s", tn, ts))
        reaper.ImGui_PopStyleColor(ctx)
      else
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_AI2_SEL))
        reaper.ImGui_Text(ctx, "  no data")
        reaper.ImGui_PopStyleColor(ctx)
      end
      reaper.ImGui_EndChild(ctx)
    end
  end

  -- ══ MORPH ════════════════════════════════════════════════════
  reaper.ImGui_Spacing(ctx)
  Widgets.drawSectionSep(ctx, dl, "MORPH")
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_TXT_PRI))
  centeredText(ctx, "MORPH CURVE")
  reaper.ImGui_PopStyleColor(ctx)

  -- Main graph (height adapts to window size)
  do
    local graph_h = Config.GRAPH_HEIGHT
    local aw      = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local gx, gy  = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, "##maingraph_morph", aw, graph_h)
    Panels.drawMainGraph(ctx, dl, gx, gy, aw, graph_h)
  end

  -- ── Morph position slider ──────────────────────────────────
  reaper.ImGui_Spacing(ctx)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx(T.C_TXT_PRI))
  centeredText(ctx, "MORPH POSITION")
  reaper.ImGui_PopStyleColor(ctx)

  local full_w     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local sld_h      = 34
  local lbl_margin = 38
  local lbl_a = (State.slot1_type == "ai")  and "AI 1"
             or (State.slot1_type == "sel") and "ENV 1" or "Src 1"
  local lbl_b = (State.slot2_type == "ai")  and "AI 2"
             or (State.slot2_type == "sel") and "ENV 2" or "Src 2"

  local sx_full, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local sld_w = full_w - lbl_margin * 2
  local sx    = sx_full + lbl_margin

  reaper.ImGui_InvisibleButton(ctx, "##morph_sld", full_w, sld_h)
  local sld_hov = reaper.ImGui_IsItemHovered(ctx)

  if sld_hov and not State.bar_dragging and reaper.ImGui_IsMouseClicked(ctx, 0)
      and not _morph_pct_editing then
    State.slider_dragging = true
  end
  -- Double-click on the track → reset to 0.5
  if sld_hov and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    State.morph = 0.5 ; State.prev_cache_key = "" ; State.slider_dragging = false
  end

  if State.slider_dragging then
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      local mx2, my2 = reaper.ImGui_GetMousePos(ctx)
      local ctrl     = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
      local shift    = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
      if ctrl then
        if not _morph_drag_start or _morph_drag_start.mode ~= "ctrl" then
          _morph_drag_start = {mode="ctrl", mx=mx2, val=State.morph}
        end
        local ds = _morph_drag_start
        State.morph = math.max(0, math.min(1, ds.val + (mx2 - ds.mx) / sld_w * 0.05))
      elseif shift then
        if not _morph_drag_start or _morph_drag_start.mode ~= "shift" then
        _morph_drag_start = {mode="shift", my=my2, val=State.morph}
       end
        local ds = _morph_drag_start
        State.morph = math.max(0, math.min(1, ds.val + (ds.my - my2) / 300))
      else
        _morph_drag_start = nil
        State.morph = math.max(0, math.min(1, (mx2 - sx) / sld_w))
      end
      MorphEngine.refreshPreviewFast()
    else
      _morph_drag_start     = nil
      State.slider_dragging = false
      State.prev_cache_key  = ""
      MorphEngine.refreshPreview()
    end
  elseif not State.bar_dragging then
    MorphEngine.refreshPreview()
  end

  local morph          = State.morph
  local pct            = math.floor(morph * 100 + 0.5)
  local unified_active = State.slider_dragging or State.bar_dragging

  -- Custom slider rendering
  do
    local trk_h    = unified_active and 10 or (sld_hov and 9 or 8)
    local trk_y    = sy + sld_h * 0.5 - trk_h * 0.5
    local grab_base = 12
    local fill_x   = sx + grab_base*0.5 + (morph * (sld_w - grab_base))
    local grab_col = unified_active and T.hx(T.C_MORPH_GRAB_HV, 1.00)
               or (sld_hov         and T.hx(T.C_MORPH_GRAB,    0.95)
               or                      T.hx(T.C_MORPH_GRAB,    0.80))

    if sld_hov or unified_active then
      reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+sld_w, sy+sld_h,
        T.rgba(0.55, 0.65, 0.75, 0.1), 4)
    end
    reaper.ImGui_DrawList_AddRectFilled(dl, sx, trk_y, sx+sld_w, trk_y+trk_h,
      T.hx(T.C_SLD_TRK), 4)

    local fill_alpha = unified_active and 0.75 or (sld_hov and 0.68 or 0.55)
    reaper.ImGui_DrawList_AddRectFilled(dl, sx, trk_y, fill_x, trk_y+trk_h,
      T.hx(T.C_MRF_SEL, fill_alpha), 4)

    local grab_w2 = unified_active and 18 or 16
    local gx1 = math.max(sx,         fill_x - grab_w2*0.5)
    local gx2 = math.min(sx + sld_w, fill_x + grab_w2*0.5)
    reaper.ImGui_DrawList_AddRectFilled(dl, gx1, sy+4, gx2, sy+sld_h-4, grab_col, 3)

    local brd_alpha = unified_active and 0.90 or (sld_hov and 0.72 or 0.55)
    reaper.ImGui_DrawList_AddRect(dl, sx, sy, sx+sld_w, sy+sld_h,
      T.hx(T.C_MORPH_GRAB, brd_alpha), 4, 0, 1.5)

    local font_h  = reaper.ImGui_GetTextLineHeight(ctx)
    local cy_lbl  = sy + (sld_h - font_h) * 0.5
    local lbl_a_w = reaper.ImGui_CalcTextSize(ctx, lbl_a)
    local lbl_b_w = reaper.ImGui_CalcTextSize(ctx, lbl_b)
    local col_a   = unified_active and T.hx(T.C_AI1_HOV, 1.0) or T.hx(T.C_AI1_HOV, 0.85)
    local col_b   = unified_active and T.hx(T.C_AI2_HOV, 1.0) or T.hx(T.C_AI2_HOV, 0.85)
    reaper.ImGui_DrawList_AddText(dl, sx_full + (lbl_margin - lbl_a_w)*0.5, cy_lbl, col_a, lbl_a)
    reaper.ImGui_DrawList_AddText(dl, sx+sld_w + (lbl_margin - lbl_b_w)*0.5, cy_lbl, col_b, lbl_b)
  end

  -- Percentage label below slider: double-click → InputText
  do
    local pct_str = string.format("%d%%", pct)
    local base_h  = reaper.ImGui_GetTextLineHeight(ctx)
    local row_h   = base_h + 6
    local rx, ry  = reaper.ImGui_GetCursorScreenPos(ctx)
    local cy      = ry + (row_h - base_h) * 0.5
    local pct_w   = reaper.ImGui_CalcTextSize(ctx, pct_str)
    local px_lbl  = rx + full_w*0.5 - pct_w*0.5

    if _morph_pct_editing then
      local input_w = math.max(60, pct_w + 20)
      reaper.ImGui_SetCursorScreenPos(ctx, rx + full_w*0.5 - input_w*0.5, cy - 2)
      reaper.ImGui_SetNextItemWidth(ctx, input_w)
      _morph_pct_frame = _morph_pct_frame + 1
      if _morph_pct_frame == 1 then reaper.ImGui_SetKeyboardFocusHere(ctx) end

      local changed, buf2 = reaper.ImGui_InputText(ctx, "##morph_pct_ed", _morph_pct_buf)
      if changed then _morph_pct_buf = buf2 end

      local enter = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
                or  reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false)
      local clicked_outside = reaper.ImGui_IsMouseClicked(ctx, 0)
                          and not reaper.ImGui_IsItemHovered(ctx)
                          and _morph_pct_frame > 2
      if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
        _morph_pct_editing = false
      elseif enter or clicked_outside then
        local p = tonumber(_morph_pct_buf)
        if p then
          State.morph = math.max(0, math.min(1, p / 100))
          State.prev_cache_key = ""
          MorphEngine.refreshPreview()
        end
        _morph_pct_editing = false
      end
      reaper.ImGui_Dummy(ctx, full_w, row_h)
    else
      reaper.ImGui_DrawList_AddRectFilled(dl, px_lbl-3, cy-1, px_lbl+pct_w+3, cy+base_h+1,
        T.hx(T.C_BG_MAIN, 0.80), 2)
      reaper.ImGui_DrawList_AddText(dl, px_lbl, cy, T.hx(T.C_TXT_PRI, 0.95), pct_str)
      reaper.ImGui_SetCursorScreenPos(ctx, px_lbl - 10, cy - 2)
      reaper.ImGui_InvisibleButton(ctx, "##morph_pct_click", pct_w + 20, base_h + 4)
      if reaper.ImGui_IsItemHovered(ctx) and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
        _morph_pct_editing = true
        _morph_pct_buf     = tostring(pct)
        _morph_pct_frame   = 0
      end
      reaper.ImGui_SetCursorScreenPos(ctx, rx, ry)
      reaper.ImGui_Dummy(ctx, full_w, row_h)
    end
  end

  -- ══ OPTIONS ══════════════════════════════════════════════════
  reaper.ImGui_Spacing(ctx)
  Widgets.drawSectionSep(ctx, dl, "OPTIONS")
  Panels.drawMorphPanel(ctx)

  -- ══ INSERT ═══════════════════════════════════════════════════
  reaper.ImGui_Spacing(ctx)
  Widgets.drawSectionSep(ctx, dl, "INSERT")
  Panels.drawGeneratePanel(ctx, dl, ctx_info)

  -- Context info + status bar
  reaper.ImGui_Spacing(ctx)
  Panels.drawContextPanel(ctx, dl, ctx_info)
  reaper.ImGui_Spacing(ctx)
  Panels.drawStatusBar(ctx, dl)
end

-- ── Expose pollCapture so the Hub can call it ─────────────────
Morph_Tool.pollCapture = function() Capture.pollCapture() end

-- ── STANDALONE LOGIC (runs only when launched standalone) ─────
local function standalone_main()
  local ctx = reaper.ImGui_CreateContext(script_name)
  Logger.ok("Capture Source 1 & 2 (AI or envelope points)")

  local SW = require("StandaloneWindow")
  SW.run(ctx, script_name, {
    win_w       = Config.WIN_W,
    win_h       = Config.WIN_H,
    win_min_w   = Config.WIN_MIN_W,
    win_min_h   = Config.WIN_MIN_H,
    win_max_w   = Config.WIN_MAX_W,
    win_max_h   = Config.WIN_MAX_H,
    ext_state_key = "ReaCurve_MORPH",
  }, Morph_Tool.drawUI, {
    pre_frame = function() Capture.pollCapture() end,
    child_id  = "##morph_content",
  })
end

-- Detection: if SLK_HUB_IN_USE is not defined, launch standalone mode
if not SLK_HUB_IN_USE then
  standalone_main()
end

return Morph_Tool
