-- ============================================================
--   SCULPTPanel.lua
--   Redesigned UI panels for the Envelope Manipulator.
--
--   Layout:
--     OPERATIONS  – action buttons (Rnd/Mirror/Invert/RndAll)
--     SHAPE       – 8 buttons × 2 rows + tension slider (live)
--     RANGE       – amplitude range for random ops
--     AMPLITUDE   – Baseline (slider) · Amplitude (slider)
--                   Amp Skew (knob + illus)
--                   Tilt + Tilt Curve (knobs + illus)
--     TIMING      – Skew (slider) + Pivot (knob, same line)
--                   H Compress + Anchor (knobs + illus)
--     SWING       – Swing (slider) + odd/even toggle
--     CONTEXT / STATUS BAR
-- ============================================================

local M = {}

local Theme   = require("Theme")
local Logger  = require("Logger")
local Widgets = require("Widgets")
local Logic   = require("SCULPTWrite")
local S       = require("SCULPTState")
local Anim    = require("Anim")
local Slider  = require("Slider")
local Toggle  = require("Toggle")
local T       = Theme

-- ── Constants ─────────────────────────────────────────────────
local VI_ON_BG  = Widgets.VI_BG
local VI_ON_HOV = Widgets.VI_HOV
local VI_ON_BRD = Widgets.VI_BRD

-- Knob dimensions (aliases to shared constants)
local KNOB_D = Widgets.KNOB_D
local KNOB_W = Widgets.KNOB_W

-- Fixed graph height: uniform for ALL inline illustrations
local ILL_H_GRAPH = 52  -- px (side graphs next to sliders + combined graph)

-- ── Fade system for conditional sections ─────────────────────
local sectionAlpha = Anim.newSectionFader(0.30)

-- ── Section separator ─────────────────────────────────────────
function M.drawSectionSep(ctx, dl, label, alpha)
  Widgets.drawSectionSep(ctx, dl, label, alpha)
end

-- ── Toggle wrapper ────────────────────────────────────────────
local function drawToggle(ctx, id, w, h, lbl_a, lbl_b, is_a, disabled)
  return Toggle.draw(ctx, id, w, h, lbl_a, lbl_b, is_a, { disabled = disabled })
end

-- ── Slider / Knob helpers ─────────────────────────────────────
local _op_hover_times = {}   -- hover-delay timers for operation buttons (key = label)
local OP_HOVER_DELAY  = 0.3  -- seconds, matches dock_hover_time delay

-- Alpha multiplier for DrawList calls (set before slider calls for fade animations)
local _draw_alpha = 1.0

local function drawFloatSlider(ctx, id, label, v, vmin, vmax, fmt, w, dis, def, h_override)
  return Slider.draw(ctx, id, label, v, vmin, vmax, fmt, w, dis, false, def,
    { sld_h = h_override or 22, gap=4, alpha=_draw_alpha, return_active=true })
end

-- ── Modifier wrappers ─────────────────────────────────────────
local _mod_prev = {}
local _prev_had_ref = false

local function modSlider(ctx, env, id, lbl, getter, setter, vmin, vmax, fmt, w, undo_lbl, def, disabled)
  local cur = getter()
  local nv, act = drawFloatSlider(ctx, id, lbl, cur, vmin, vmax, fmt, w, disabled or false, def)
  if not disabled and nv ~= cur then setter(nv) ; Logic.applyModifiers(env) end
  if _mod_prev[id] and not act then if not disabled then Logic.commitUndo(undo_lbl or ("Adjust "..lbl)) end end
  _mod_prev[id] = act
end

local function modKnob(ctx, env, id, lbl, getter, setter, vmin, vmax, fmt, undo_lbl, def, disabled)
  local cur = getter()
  local nv, act = Widgets.drawKnob(ctx, id, lbl, cur, vmin, vmax, fmt, disabled or false, def)
  if not disabled and nv ~= cur then setter(nv) ; Logic.applyModifiers(env) end
  if _mod_prev[id] and not act then if not disabled then Logic.commitUndo(undo_lbl or ("Adjust "..lbl)) end end
  _mod_prev[id] = act
end

-- Widgets.drawKnob wrapper that temporarily overrides the arc fill colour.
local function drawKnobAccent(ctx, id, label, value, vmin, vmax, fmt, disabled, default_val, accent_hex)
  local saved_grab    = T.C_MORPH_GRAB
  local saved_grab_hv = T.C_MORPH_GRAB_HV
  T.C_MORPH_GRAB    = accent_hex
  T.C_MORPH_GRAB_HV = accent_hex
  local nv, act = Widgets.drawKnob(ctx, id, label, value, vmin, vmax, fmt, disabled, default_val)
  T.C_MORPH_GRAB    = saved_grab
  T.C_MORPH_GRAB_HV = saved_grab_hv
  return nv, act
end

local function modKnobAccent(ctx, env, id, lbl, getter, setter, vmin, vmax, fmt, undo_lbl, def, accent_hex, disabled)
  local cur = getter()
  local nv, act = drawKnobAccent(ctx, id, lbl, cur, vmin, vmax, fmt, disabled or false, def, accent_hex)
  if not disabled and nv ~= cur then setter(nv) ; Logic.applyModifiers(env) end
  if _mod_prev[id] and not act then if not disabled then Logic.commitUndo(undo_lbl or ("Adjust "..lbl)) end end
  _mod_prev[id] = act
end

-- ── Pill switch (Even / Odd toggle) ──────────────────────────
-- Same visual style as drawToggle (Keep Edges):
-- Active side : VI_ON_BG fill + #E8DDFF border 1.5px + bright text.
-- Inactive side: transparent + C_DISABLED text.
-- Uses InvisibleButton so the caller fully controls position.
local function drawPillSwitch(ctx, id, w, h, lbl_left, lbl_right, is_right, disabled)
  local dl     = reaper.ImGui_GetWindowDrawList(ctx)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local rad    = math.floor(h * 0.5)
  local fh     = reaper.ImGui_GetTextLineHeight(ctx)
  local hw     = math.floor((w - 2) * 0.5)

  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_InvisibleButton(ctx, "##psw_"..id, w, h)
  local hov     = reaper.ImGui_IsItemHovered(ctx)
  local clicked = reaper.ImGui_IsItemClicked(ctx, 0)
  if disabled then reaper.ImGui_EndDisabled(ctx) end

  -- Overall pill background + outer border (mirrors drawToggle)
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+w, sy+h,
    T.hx(T.C_BG_MAIN, disabled and 0.40 or 0.70), rad)
  reaper.ImGui_DrawList_AddRect(dl, sx, sy, sx+w, sy+h,
    T.hx(VI_ON_BRD, disabled and 0.20 or 0.45), rad, 0, 1.0)
  -- Centre divider
  reaper.ImGui_DrawList_AddLine(dl, sx+hw+1, sy+2, sx+hw+1, sy+h-2,
    T.hx(VI_ON_BRD, disabled and 0.15 or 0.30), 1.0)

  -- Active side fill + thick bright border
  if not disabled then
    if not is_right then
      reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+hw, sy+h, T.hx(VI_ON_BG), rad)
      reaper.ImGui_DrawList_AddRect(dl, sx, sy, sx+hw+1, sy+h, T.hx("#E8DDFF"), rad, 0, 1.5)
    else
      reaper.ImGui_DrawList_AddRectFilled(dl, sx+hw, sy, sx+w, sy+h, T.hx(VI_ON_BG), rad)
      reaper.ImGui_DrawList_AddRect(dl, sx+hw-1, sy, sx+w, sy+h, T.hx("#E8DDFF"), rad, 0, 1.5)
    end
  end

  -- Hover tint on the inactive half
  if hov and not disabled then
    local hx = is_right and sx or (sx + hw)
    reaper.ImGui_DrawList_AddRectFilled(dl, hx, sy, hx+hw, sy+h, T.hx(VI_ON_BG, 0.25), rad)
  end

  -- Labels centred in each half
  local function sideLabel(lbl, cx, is_active)
    local lw = reaper.ImGui_CalcTextSize(ctx, lbl)
    local tx = cx - lw * 0.5
    local ty = sy + (h - fh) * 0.5
    local col = disabled and T.hx(T.C_DISABLED, 0.40)
             or (is_active and T.hx(T.C_TXT_PRI) or T.hx(T.C_DISABLED))
    reaper.ImGui_DrawList_AddText(dl, math.floor(tx), math.floor(ty), col, lbl)
  end
  sideLabel(lbl_left,  sx + hw * 0.5,      not is_right)
  sideLabel(lbl_right, sx + hw + hw * 0.5, is_right)

  return not disabled and clicked
end

-- ── Illustrations ─────────────────────────────────────────────
-- Small animated diagrams showing what each parameter does.

local ILL_BG  = T.C_BG_PANEL
local ILL_BRD = T.C_BORDER

-- Clamp helper
local function cl(v) return math.max(0, math.min(1, v)) end

-- Background box + center line
local function illBox(dl, px, py, pw, ph)
  reaper.ImGui_DrawList_AddRectFilled(dl, px, py, px+pw, py+ph, T.hx(T.C_BG_PANEL, 0.95), 3)
  reaper.ImGui_DrawList_AddRect(dl, px, py, px+pw, py+ph, T.hx(T.C_BORDER, 0.55), 3, 0, 0.8)
  local mid_y = py + ph*0.5
  reaper.ImGui_DrawList_AddLine(dl, px+4, mid_y, px+pw-4, mid_y, T.hx("#FFFFFF", 0.07), 1.0)
end

-- Draw a polyline from normalized (tn, v) pairs [0,1]×[0,1]
local function illPoly(dl, px, py, pw, ph, pts, col, thick)
  local ix, iy, iw, ih = px+4, py+4, pw-8, ph-8
  local lw = thick or 1.4
  local prev_x, prev_y
  for _, p in ipairs(pts) do
    local x = ix + p[1]*iw
    local y = iy + (1-p[2])*ih
    if prev_x then reaper.ImGui_DrawList_AddLine(dl, prev_x, prev_y, x, y, col, lw) end
    reaper.ImGui_DrawList_AddCircleFilled(dl, x, y, 2.0, col)
    prev_x, prev_y = x, y
  end
end

-- BASE waveform (5 points): original shape reference
local BASE = {{0,0.50},{0.25,0.82},{0.50,0.28},{0.75,0.74},{1,0.38}}

-- ── Baseline illustration ─────────────────────────────────────
local function illBaseline(dl, px, py, pw, ph, val)
  illBox(dl, px, py, pw, ph)
  -- Original (gray)
  illPoly(dl, px, py, pw, ph, BASE, T.hx("#FFFFFF", 0.20), 1.0)
  -- Shifted (green)
  local shifted = {}
  for _, p in ipairs(BASE) do shifted[#shifted+1] = {p[1], cl(p[2] + val*0.5)} end
  illPoly(dl, px, py, pw, ph, shifted, T.hx(T.C_MRF_BASE, 0.75), 1.5)
  -- Arrow indicator
  if math.abs(val) > 0.03 then
    local cx  = px + pw*0.5
    local by2 = py + ph*0.5
    local ay  = by2 - val * ph * 0.28
    reaper.ImGui_DrawList_AddLine(dl, cx, by2, cx, ay, T.hx(T.C_MRF_HOV, 0.7), 1.5)
    local dir = val > 0 and -1 or 1
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      cx-3.5, ay+dir*5, cx+3.5, ay+dir*5, cx, ay, T.hx(T.C_MRF_HOV, 0.7))
  end
end

-- ── Amplitude illustration ────────────────────────────────────
local function illAmplitude(dl, px, py, pw, ph, val)
  illBox(dl, px, py, pw, ph)
  illPoly(dl, px, py, pw, ph, BASE, T.hx("#FFFFFF", 0.20), 1.0)
  local scaled = {}
  for _, p in ipairs(BASE) do
    local nv = 0.5 + (p[2]-0.5) * val   -- val<0 inverts (mirrors), val=0 flat
    scaled[#scaled+1] = {p[1], cl(nv)}
  end
  illPoly(dl, px, py, pw, ph, scaled, T.hx(T.C_MRF_BASE, 0.75), 1.5)
end

-- ── Amp Skew illustration (amplitude ramp across time) ────────
-- (kept for standalone use, same size as baseline/amp graphs)
local function illAmpSkew(dl, px, py, pw, ph, val)
  illBox(dl, px, py, pw, ph)
  illPoly(dl, px, py, pw, ph, BASE, T.hx("#FFFFFF", 0.20), 1.0)
  local skewed = {}
  for _, p in ipairs(BASE) do
    local mult = val >= 0 and ((1-val) + val*p[1]) or ((1+val) - val*(1-p[1]))
    skewed[#skewed+1] = {p[1], cl(0.5 + (p[2]-0.5)*mult)}
  end
  illPoly(dl, px, py, pw, ph, skewed, T.hx(T.C_MRF_BASE, 0.75), 1.5)
end

-- ── Combined Amplitude illustration ──────────────────────────
-- Shows BASE (gray), amp_skew+tilt+tilt_curve result (green),
-- and the tilt curve shape as an orange overlay.
local function illCombined(dl, px, py, pw, ph, amp_skew, tilt, tilt_curve)
  illBox(dl, px, py, pw, ph)
  illPoly(dl, px, py, pw, ph, BASE, T.hx("#FFFFFF", 0.18), 1.0)

  -- Pass 1: amp_skew
  local inter = {}
  for _, p in ipairs(BASE) do
    local mult = amp_skew >= 0 and ((1-amp_skew) + amp_skew*p[1])
                                or ((1+amp_skew) - amp_skew*(1-p[1]))
    inter[#inter+1] = cl(0.5 + (p[2]-0.5)*mult)
  end

  -- Dynamic range for tilt
  local v_min, v_max = math.huge, -math.huge
  for _, nv in ipairs(inter) do
    if nv < v_min then v_min = nv end
    if nv > v_max then v_max = nv end
  end
  local mid_v = (v_min + v_max) * 0.5

  -- Pass 2: tilt + tilt_curve → green result curve
  local result = {}
  for k, p in ipairs(BASE) do
    local nv = inter[k]
    if tilt ~= 0 then
      local tc = tilt_curve
      local tw = p[1]*(tc+1)*0.5 + (1-p[1])*(1-tc)*0.5
      if tilt > 0 and nv < mid_v then
        nv = cl(nv + (v_min + tw*(v_max-v_min) - nv) * tilt)
      elseif tilt < 0 and nv > mid_v then
        nv = cl(nv + (v_max + tw*(v_min-v_max) - nv) * (-tilt))
      end
    end
    result[#result+1] = {p[1], nv}
  end
  illPoly(dl, px, py, pw, ph, result, T.hx(T.C_MRF_BASE, 0.80), 1.8)

  -- Blue tilt curve shape overlay (always visible, shows the tilt weight distribution)
  do
    local ix, iy, iw, ih = px+4, py+4, pw-8, ph-8
    local steps = 32
    local prev_x2, prev_y2
    local tilt_col = T.hx("#4A9EE0", math.abs(tilt) > 0.02 and 0.70 or 0.28)
    for i = 0, steps do
      local tn  = i / steps
      local tc  = tilt_curve
      local tw  = tn*(tc+1)*0.5 + (1-tn)*(1-tc)*0.5
      -- Visual: flat line at 0.5 when tilt=0, pushed up/down proportionally
      local vy  = 0.5 - tw * tilt * 0.40
      local x   = ix + tn * iw
      local y   = iy + math.max(0, math.min(1, vy)) * ih
      if prev_x2 then
        reaper.ImGui_DrawList_AddLine(dl, prev_x2, prev_y2, x, y, tilt_col, 1.4)
      end
      prev_x2, prev_y2 = x, y
    end
  end
end

-- ── Skew/Pivot compact illustration ──────────────────────────
-- Draws a compact timeline: original grid ticks (top row) and
-- skewed ticks (bottom row) with pivot marker. Fits in a thin strip.
local function illSkewCompact(dl, px, py, pw, ph, skew, pivot)
  illBox(dl, px, py, pw, ph)
  local ix, iy, iw, ih = px+5, py+3, pw-10, ph-6
  local n_ticks = 8
  local col_orig = T.hx("#FFFFFF", 0.22)
  local col_skew = T.hx(T.C_MRF_BASE, 0.72)
  for i = 0, n_ticks do
    local t = i / n_ticks
    local t_s = t
    if skew ~= 0 then
      local pwr = math.exp(-skew * 1.4)
      local c   = math.max(0.001, math.min(0.999, pivot))
      if t <= c then
        t_s = c * ((t/c)^pwr)
      else
        t_s = c + (1-c) * (((t-c)/(1-c))^(1/pwr))
      end
    end
    local ox  = ix + t   * iw
    local sx2 = ix + t_s * iw
    -- original ticks (top half)
    reaper.ImGui_DrawList_AddLine(dl, ox,  iy,          ox,  iy+ih*0.40, col_orig, 1.0)
    -- skewed ticks (bottom half)
    reaper.ImGui_DrawList_AddLine(dl, sx2, iy+ih*0.60,  sx2, iy+ih,      col_skew, 1.2)
  end
  -- Divider
  reaper.ImGui_DrawList_AddLine(dl, ix, iy+ih*0.50, ix+iw, iy+ih*0.50, T.hx("#FFFFFF", 0.10), 1.0)
  -- Pivot marker
  local pv_x = ix + math.max(0.001, math.min(0.999, pivot)) * iw
  reaper.ImGui_DrawList_AddLine(dl, pv_x, iy, pv_x, iy+ih, T.hx(T.C_AI1_BASE, 0.50), 1.2)
end

-- ── H Compress compact illustration ──────────────────────────
-- Single thin row: dots move toward anchor.
local function illHCompressCompact(dl, px, py, pw, ph, compress, anchor)
  illBox(dl, px, py, pw, ph)
  local ix, iy, iw, ih = px+5, py+3, pw-10, ph-6
  local n = 7
  local col_o = T.hx("#FFFFFF", 0.22)
  local col_c = T.hx(T.C_MRF_BASE, 0.72)
  local anch_x = ix + anchor * iw
  for i = 0, n do
    local t  = i / n
    local tc = anchor + (t - anchor) * (1 - compress)
    local ox = ix + t  * iw
    local cx = ix + tc * iw
    -- original (top)
    reaper.ImGui_DrawList_AddCircleFilled(dl, ox, iy + ih*0.28, 2.2, col_o)
    -- compressed (bottom)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx, iy + ih*0.72, 2.2, col_c)
    -- connector arrow (center, thin)
    if compress > 0.05 and i > 0 and i < n then
      reaper.ImGui_DrawList_AddLine(dl, ox, iy+ih*0.28+3, cx, iy+ih*0.72-3,
        T.hx(T.C_MRF_SEL, 0.18), 1.0)
    end
  end
  -- Anchor line
  reaper.ImGui_DrawList_AddLine(dl, anch_x, iy, anch_x, iy+ih,
    T.hx(T.C_AI1_BASE, 0.45), 1.2)
end

-- ── Combined Timing illustration ─────────────────────────────
-- Single graph combining skew/pivot (top half) and h compress/anchor (bottom half).
-- Top:    gray=original ticks, green=skewed ticks, blue line=pivot
-- Bottom: gray=original dots,  green=compressed dots, blue line=anchor
local function illTiming(dl, px, py, pw, ph, skew, pivot, compress, anchor)
  illBox(dl, px, py, pw, ph)
  local ix, iy, iw, ih = px+5, py+3, pw-10, ph-6
  local half   = ih * 0.47   -- height of each strip
  local gap_y  = ih * 0.06   -- tiny gap between strips
  local col_o  = T.hx("#FFFFFF", 0.35)
  local col_sk = T.hx(T.C_MRF_BASE, 0.90)
  local col_hc = T.hx("#8B72E8", 0.90)
  local n_ticks = 9

  -- ── TOP STRIP: skew ──────────────────────────────────────
  local top_y = iy
  local bot_y = iy + half
  for i = 0, n_ticks do
    local t = i / n_ticks
    local t_s = t
    if skew ~= 0 then
      local pwr = math.exp(-skew * 1.4)
      local c   = math.max(0.001, math.min(0.999, pivot))
      if t <= c then t_s = c * ((t/c)^pwr)
      else           t_s = c + (1-c)*(((t-c)/(1-c))^(1/pwr)) end
    end
    local ox  = ix + t   * iw
    local sx2 = ix + t_s * iw
    -- Original tick (top of strip)
    reaper.ImGui_DrawList_AddLine(dl, ox,  top_y,          ox,  top_y+half*0.45, col_o,  1.0)
    -- Skewed tick (bottom of strip)
    reaper.ImGui_DrawList_AddLine(dl, sx2, top_y+half*0.55, sx2, bot_y,          col_sk, 1.3)
  end
  -- Centre divider of skew strip
  reaper.ImGui_DrawList_AddLine(dl, ix, top_y+half*0.50, ix+iw, top_y+half*0.50, T.hx("#FFFFFF", 0.12), 1.0)
  -- Pivot marker (bright blue-white vertical)
  local pv_x = ix + math.max(0.001, math.min(0.999, pivot)) * iw
  reaper.ImGui_DrawList_AddLine(dl, pv_x, top_y, pv_x, bot_y, T.hx("#7AB8F5", 0.85), 1.5)

  -- Separator between strips
  local sep_y = iy + half + gap_y
  reaper.ImGui_DrawList_AddLine(dl, ix, sep_y, ix+iw, sep_y, T.hx("#FFFFFF", 0.12), 1.0)

  -- ── BOTTOM STRIP: h compress ──────────────────────────────
  local t2_y   = sep_y + gap_y
  local b2_y   = iy + ih
  local strip2 = b2_y - t2_y
  local n2     = 8
  local anch_x = ix + anchor * iw
  for i = 0, n2 do
    local t   = i / n2
    local tc  = anchor + (t - anchor) * (1 - compress)
    local ox2 = ix + t  * iw
    local cx2 = ix + tc * iw
    -- Original dot (top of strip)
    reaper.ImGui_DrawList_AddCircleFilled(dl, ox2, t2_y + strip2*0.28, 2.2, col_o)
    -- Compressed dot (bottom of strip)
    reaper.ImGui_DrawList_AddCircleFilled(dl, cx2, t2_y + strip2*0.72, 2.2, col_hc)
    -- Connector (only when compressing, skip edges)
    if compress > 0.06 and i > 0 and i < n2 then
      reaper.ImGui_DrawList_AddLine(dl,
        ox2, t2_y+strip2*0.28+3, cx2, t2_y+strip2*0.72-3,
        T.hx(T.C_AI2_SEL, 0.20), 1.0)
    end
  end
  -- Anchor marker (bright violet, full bottom-strip height)
  reaper.ImGui_DrawList_AddLine(dl, anch_x, t2_y, anch_x, b2_y, T.hx("#A080FF", 0.90), 1.5)
end
-- ═══════════════════════════════════════════════════════════════
--   PANELS
-- ═══════════════════════════════════════════════════════════════

-- ── OPERATIONS ────────────────────────────────────────────────
function M.drawOperationsPanel(ctx)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gap = 5
  local bh  = 25
  local bw2 = math.floor((avw-gap)/2)
  local fh  = reaper.ImGui_GetTextLineHeight(ctx)
  local has = (S.ref_entries and #S.ref_entries > 0)

  -- ── sub-section helper ──────────────────────────────────────
  local function subSep(label)
    local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local sw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local lw     = reaper.ImGui_CalcTextSize(ctx, label)
    reaper.ImGui_DrawList_AddText(dl, sx, sy, T.hx(T.C_DISABLED, 0.70), label)
    reaper.ImGui_DrawList_AddLine(dl, sx+lw+6, sy+fh*0.5, sx+sw, sy+fh*0.5,
      T.hx("#FFFFFF", 0.10))
    reaper.ImGui_Dummy(ctx, sw, fh-2)
  end

  -- ── RANGE sub-section ───────────────────────────────────────
  subSep("Range")

  local rng_items = {}
  for i, r in ipairs(Logic.RANGES) do rng_items[i] = { id = i, label = r.label } end
  local new_rng = Widgets.drawViButtonRow(ctx, dl, rng_items, S.range_type,
    { bh=24, gap=gap, rounding=4, prefix="##opRng", disabled=not has })
  if has and new_rng ~= S.range_type then S.range_type = new_rng end

  if drawToggle(ctx, "rnd_edges", avw, 22, "Keep Edges", "Rnd Edges", not S.rnd_edges, not has) then
    S.rnd_edges = not S.rnd_edges
  end

  reaper.ImGui_Dummy(ctx, avw, 4)

  -- ── RANDOMIZATION sub-section ───────────────────────────────
  subSep("Randomization")

  local has    = (S.ref_entries and #S.ref_entries > 0)
  local dis_op = not has   -- grey operation buttons when nothing selected

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.2)
  local function opBtn(w, h, lbl, bg, hov, tip)
    if dis_op then reaper.ImGui_BeginDisabled(ctx) end
    T.pushButtonHex(ctx, bg, hov, T.C_TXT_PRI)
    local p = reaper.ImGui_Button(ctx, lbl, w, h)
    if tip and reaper.ImGui_IsItemHovered(ctx) then
      if not _op_hover_times[lbl] then _op_hover_times[lbl] = reaper.time_precise() end
      if (reaper.time_precise() - _op_hover_times[lbl]) > OP_HOVER_DELAY then
        reaper.ImGui_SetTooltip(ctx, tip)
      end
    else
      _op_hover_times[lbl] = nil
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
    if dis_op then reaper.ImGui_EndDisabled(ctx) end
    return p and not dis_op
  end

  -- Row 1: 4 compact buttons in one line
  local n4   = 4
  local bw4  = math.floor((avw - gap*(n4-1)) / n4)
  local bh4  = 22
  if opBtn(bw4, bh4, "Rnd Val",  "#1A2840","#2A3A5A",
      "Randomize point values\nwithin the selected range") then Logic.doRndValues()  end
  reaper.ImGui_SameLine(ctx, 0, gap)
  if opBtn(bw4, bh4, "Rnd Pos",  "#1A2840","#2A3A5A",
      "Randomize point positions\nalong the time axis") then Logic.doRndPos() end
  reaper.ImGui_SameLine(ctx, 0, gap)
  if opBtn(bw4, bh4, "Mirror",   "#1A2840","#2A3A5A",
      "Flip values vertically") then Logic.doMirrorAmp() end
  reaper.ImGui_SameLine(ctx, 0, gap)
  if opBtn(bw4, bh4, "Inv Time", "#1A2840","#2A3A5A",
      "Reverse point order horizontally") then Logic.doInvertTime() end

  -- Row 2: RANDOM ALL (centered, ~65% width)
  local rall_w = math.floor(avw * 0.50)
  local rall_x = select(1, reaper.ImGui_GetCursorScreenPos(ctx)) + math.floor((avw - rall_w) * 0.5)
  reaper.ImGui_SetCursorScreenPos(ctx, rall_x, select(2, reaper.ImGui_GetCursorScreenPos(ctx)))
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(), 10, 5)
  if opBtn(rall_w, bh+2, "RANDOM ALL", "#1A2840","#2A3A5A",
      "Randomize positions, values AND shape type\nin one operation") then Logic.doRndAll() end
  reaper.ImGui_PopStyleVar(ctx)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

-- ── SHAPE (8 buttons × 2 rows, uniform design) ───────────────
-- Row 1: ORIG | Lin | Sq | SlwS/E
-- Row 2: Fst+ | Fst- | Bezier | RND
local SHAPE_DEFS = {
  {id=7, text="ORIG"},
  {id=0}, {id=1}, {id=2},
  {id=3}, {id=4}, {id=5}, {id=6, text="RND"},
}

local _prev_tension = S.tension

function M.drawShapePanel(ctx, env)
  local dl   = reaper.ImGui_GetWindowDrawList(ctx)
  local avw  = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gap  = 3
  local bh   = 30
  local cols = 8
  local bw   = math.floor((avw - gap*(cols-1)) / cols)
  local has  = (S.ref_entries and #S.ref_entries > 0)

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   5)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)

  local shape_changed = false
  for i, sh in ipairs(SHAPE_DEFS) do
    local active  = (S.point_type == sh.id)
    local dis_btn = not has

    if active then
      if sh.id == 6 or sh.id == 7 then
        -- ORIG / RND actif : bleu Rnd Positions
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx("#1A2840"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx("#2A3A5A"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx("#3A4A6A"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx("#4A7AAD"))
      else
        -- Shape standard actif : violet
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_AI2_SEL))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_AI2_HOV))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx("#6A55DE"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_AI2_BASE))
      end
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_AI2_BG))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_AI2_SEL, 0.55))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_DISABLED))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_BORDER))
    end

    if dis_btn then reaper.ImGui_BeginDisabled(ctx) end
    local pressed = reaper.ImGui_Button(ctx, "##shbtn"..i, bw, bh)
    if dis_btn then reaper.ImGui_EndDisabled(ctx) end

    local bx, by   = reaper.ImGui_GetItemRectMin(ctx)
    local bw2, bh2 = reaper.ImGui_GetItemRectSize(ctx)
    local ic_col   = dis_btn and T.hx(T.C_DISABLED, 0.35)
                  or (active and T.hx(T.C_TXT_PRI, 0.95) or T.hx(T.C_DISABLED, 0.75))
    if sh.text then
      local lw, lh = reaper.ImGui_CalcTextSize(ctx, sh.text)
      reaper.ImGui_DrawList_AddText(dl,
        math.floor(bx+(bw2-lw)*0.5), math.floor(by+(bh2-lh)*0.5), ic_col, sh.text)
    else
      Widgets.drawShapeIcon(dl, ctx, bx, by, bw2, bh2, sh.id, ic_col)
    end
    reaper.ImGui_PopStyleColor(ctx, 5)

    if pressed and not dis_btn then
      if sh.id == 6 then
        S.point_type = 6
        Logic.doRndShape()
      elseif sh.id == 7 then
        S.point_type = 7
        Logic.doRestoreShapeTypeOnly(env)
      else
        S.point_type = sh.id
        if sh.id ~= 5 then S.tension = 0.0 end
        shape_changed = true
      end
    end

    local col_idx = (i-1) % cols
    if col_idx < cols-1 then reaper.ImGui_SameLine(ctx, 0, gap) end
  end

  reaper.ImGui_PopStyleVar(ctx, 2)

  -- Tension slider: fade in/out (ease smoothstep) when Bezier is selected
  local is_bz = (S.point_type == 5)
  local bz_alpha, bz_vis = sectionAlpha("shape_tension", is_bz)
  if bz_vis then
    _draw_alpha = bz_alpha * (has and 1.0 or 0.35)
    if not has then reaper.ImGui_BeginDisabled(ctx) end
    local avw2 = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local new_tn, tn_act = drawFloatSlider(ctx, "Tension",
      "Tension", S.tension, -1.0, 1.0, "%.2f", avw2, false, 0.0, 16)
    if not has then reaper.ImGui_EndDisabled(ctx) end
    _draw_alpha = 1.0
    if new_tn ~= S.tension then
      S.tension = new_tn ; shape_changed = true
    end
    if _prev_tension ~= new_tn and not tn_act and S.ref_entries and #S.ref_entries > 0 then
      Logic.commitUndo("Apply Shape")
    end
    _prev_tension = new_tn
  else
    _prev_tension = S.tension
  end

  if shape_changed and S.ref_entries and #S.ref_entries > 0 then
    Logic.applyShapeLive(env)
    Logic.commitUndo("Apply Shape")
  end
end

-- ── RANGE panel ───────────────────────────────────────────────
function M.drawRangePanel(ctx)
  local dl   = reaper.ImGui_GetWindowDrawList(ctx)
  local avw  = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local has  = (S.ref_entries and #S.ref_entries > 0)

  local items = {}
  for i, r in ipairs(Logic.RANGES) do items[i] = { id = i, label = r.label } end
  local new = Widgets.drawViButtonRow(ctx, dl, items, S.range_type,
    { bh=24, gap=3, rounding=4, prefix="##rng", disabled=not has })
  if has and new ~= S.range_type then S.range_type = new end

  local avw2 = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local desc = Logic.RANGES[S.range_type].desc
  local dw   = reaper.ImGui_CalcTextSize(ctx, desc)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local fh2  = reaper.ImGui_GetTextLineHeight(ctx)
  reaper.ImGui_DrawList_AddText(reaper.ImGui_GetWindowDrawList(ctx),
    sx + (avw2-dw)*0.5, sy+2, T.hx(T.C_DISABLED, 0.80), desc)
  reaper.ImGui_Dummy(ctx, avw2, fh2+4)
  if drawToggle(ctx, "rnd_edges", avw2, 22, "Keep Edges", "Rnd Edges", not S.rnd_edges, not has) then
    S.rnd_edges = not S.rnd_edges
  end
end

-- ── AMPLITUDE section ─────────────────────────────────────────
-- Layout:
--   [Baseline slider  ──────────────] [graph ILL_H_GRAPH]
--   [Amplitude slider ──────────────] [graph ILL_H_GRAPH]
--   [Amp Skew knob] [Tilt knob] [Tilt Curve knob]
--   [── Combined graph (full width, ILL_H_GRAPH) ──────────────]
function M.drawAmplitudeSection(ctx, env)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local has = (S.ref_entries and #S.ref_entries > 0)
  local dis = not has

  -- Shared proportions: slider 62%, graph 38%
  local ill_w = math.floor(avw * 0.38)
  local sld_w = avw - ill_w - 6

  -- ── Baseline ─────────────────────────────────────────────────
  local bl_sx, bl_sy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_BeginGroup(ctx)
  modSlider(ctx,env,"baseline","Baseline",
    function() return S.baseline end, function(v) S.baseline=v end,
    -1.0, 1.0, "%.2f", sld_w, "Adjust Baseline", 0.0, dis)
  reaper.ImGui_EndGroup(ctx)
  reaper.ImGui_SameLine(ctx, 0, 6)
  do
    local ix, iy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, "##ill_bl", ill_w, ILL_H_GRAPH)
    illBaseline(dl, ix, iy, ill_w, ILL_H_GRAPH, S.baseline)
    if dis then
      reaper.ImGui_DrawList_AddRectFilled(dl, ix, iy, ix+ill_w, iy+ILL_H_GRAPH,
        T.hx(T.C_BG_PANEL, 0.65), 3)
    end
    local after_x, after_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local bottom = bl_sy + ILL_H_GRAPH + 4
    if after_y < bottom then
      reaper.ImGui_SetCursorScreenPos(ctx, after_x, bottom)
    end
  end

  -- ── Amplitude Scale ───────────────────────────────────────────
  local amp_sx, amp_sy = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_BeginGroup(ctx)
  modSlider(ctx,env,"amplitude","Amplitude Scale",
    function() return S.amplitude end, function(v) S.amplitude=v end,
    -2.0, 2.0, "%.2f", sld_w, "Adjust Amplitude", 1.0, dis)
  reaper.ImGui_EndGroup(ctx)
  reaper.ImGui_SameLine(ctx, 0, 6)
  do
    local ix, iy = reaper.ImGui_GetCursorScreenPos(ctx)
    reaper.ImGui_InvisibleButton(ctx, "##ill_amp", ill_w, ILL_H_GRAPH)
    illAmplitude(dl, ix, iy, ill_w, ILL_H_GRAPH, S.amplitude)
    if dis then
      reaper.ImGui_DrawList_AddRectFilled(dl, ix, iy, ix+ill_w, iy+ILL_H_GRAPH,
        T.hx(T.C_BG_PANEL, 0.65), 3)
    end
    local after_x, after_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local bottom = amp_sy + ILL_H_GRAPH + 4
    if after_y < bottom then
      reaper.ImGui_SetCursorScreenPos(ctx, after_x, bottom)
    end
  end

  -- ── Knob row: Amp Skew | Tilt | Tilt Curve  +  combined graph ──
  reaper.ImGui_Dummy(ctx, avw, 2)
  local knob_row_sx, knob_row_sy = reaper.ImGui_GetCursorScreenPos(ctx)

  -- Centre les 3 knobs dans la colonne sld_w
  local knobs_total = 3 * KNOB_W + 2 * 6
  local knob_indent = math.max(0, math.floor((sld_w - knobs_total) / 2))
  reaper.ImGui_SetCursorScreenPos(ctx, knob_row_sx + knob_indent, knob_row_sy)

  -- Knobs — Tilt & Tilt Curve in blue
  modKnob(ctx,env,"amp_skew","Amp Skew",
    function() return S.amp_skew end, function(v) S.amp_skew=v end,
    -1.0, 1.0, "%.2f", "Adjust Amp Skew", 0.0, dis)
  reaper.ImGui_SameLine(ctx, 0, 6)
  modKnobAccent(ctx,env,"tilt","Tilt",
    function() return S.tilt end, function(v) S.tilt=v end,
    -1.0, 1.0, "%.2f", "Adjust Tilt", 0.0, "#4A9EE0", dis)
  reaper.ImGui_SameLine(ctx, 0, 6)
  modKnobAccent(ctx,env,"tilt_curve","Tilt Curve",
    function() return S.tilt_curve end, function(v) S.tilt_curve=v end,
    -1.0, 1.0, "%.2f", "Adjust Tilt Curve", 1.0, "#4A9EE0", dis)

  -- Graph: same x-offset and width as side graphs
  local cg_x = knob_row_sx + sld_w + 6
  local cg_y = knob_row_sy
  illCombined(dl, cg_x, cg_y, ill_w, ILL_H_GRAPH, S.amp_skew, S.tilt, S.tilt_curve)
  if dis then
    reaper.ImGui_DrawList_AddRectFilled(dl, cg_x, cg_y, cg_x+ill_w, cg_y+ILL_H_GRAPH,
      T.hx(T.C_BG_PANEL, 0.65), 3)
  end

  -- Cursor below the row
  local _, after_y2 = reaper.ImGui_GetCursorScreenPos(ctx)
  local row_bottom = knob_row_sy + ILL_H_GRAPH + 4
  reaper.ImGui_SetCursorScreenPos(ctx, knob_row_sx,
    after_y2 < row_bottom and row_bottom or after_y2)
end

-- ── TIMING section ────────────────────────────────────────────
-- Layout:
--   Swing slider + odd/even toggle  (first)
--   [Skew slider  ──────────────] [H Compress knob]
--   [Pivot slider ──────────────] [Anchor knob]
--   [Combined timing graph, full width, ILL_H_GRAPH]
--   Reset All Modifiers button
function M.drawTimingSection(ctx, env)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local has = (S.ref_entries and #S.ref_entries > 0)
  local dis = not has

  -- Column proportions (shared by swing, skew, pivot rows)
  local ill_w = math.floor(avw * 0.38)
  local sld_w = avw - ill_w - 6

  -- ── Swing row: slider left col + pill switch right col ───────
  -- The pill switch is vertically centred on the entire slider widget height.
  do
    local row_sx, row_sy = reaper.ImGui_GetCursorScreenPos(ctx)

    -- Draw slider in left col, capture its total height
    reaper.ImGui_BeginGroup(ctx)
    modSlider(ctx,env,"swing","Swing",
      function() return S.swing end, function(v) S.swing=v end,
      -1.0, 1.0, "%.2f", sld_w, "Adjust Swing", 0.0, dis)
    reaper.ImGui_EndGroup(ctx)
    local _, slider_total_h = reaper.ImGui_GetItemRectSize(ctx)
    reaper.ImGui_SameLine(ctx, 0, 6)

    -- Pill switch: vertically centred in slider_total_h
    local pill_h = 22
    local tog_sx, tog_sy = reaper.ImGui_GetCursorScreenPos(ctx)
    -- Align pill centre to slider centre
    local pill_y = row_sy + math.floor((slider_total_h - pill_h) * 0.5)
    reaper.ImGui_SetCursorScreenPos(ctx, tog_sx, pill_y)
    if drawPillSwitch(ctx, "swing_parity", ill_w, pill_h, "Even", "Odd", not S.swing_odd, dis) then
      S.swing_odd = not S.swing_odd
      if has then Logic.applyModifiers(env) end
    end

    -- Cursor below the taller element
    local after_x, after_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local bottom = row_sy + slider_total_h + 2
    if after_y < bottom then
      reaper.ImGui_SetCursorScreenPos(ctx, after_x, bottom)
    end
  end

  -- reaper.ImGui_Dummy(ctx, avw, 2)

  -- ── Row 1: Skew slider | H Compress knob (violet) ────────────
  local row1_sy = select(2, reaper.ImGui_GetCursorScreenPos(ctx))
  reaper.ImGui_BeginGroup(ctx)
  modSlider(ctx,env,"freq_skew","Skew",
    function() return S.freq_skew end, function(v) S.freq_skew=v end,
    -1.0, 1.0, "%.2f", sld_w, "Adjust Skew", 0.0, dis)
  reaper.ImGui_EndGroup(ctx)
  reaper.ImGui_SameLine(ctx, 0, 6)
  do
    local right_sx, right_sy = reaper.ImGui_GetCursorScreenPos(ctx)
    local knob_cx = right_sx + math.floor((ill_w - KNOB_W) * 0.5)
    reaper.ImGui_SetCursorScreenPos(ctx, knob_cx, right_sy)
    modKnobAccent(ctx,env,"h_compress","H Compress",
      function() return S.h_compress end, function(v) S.h_compress=v end,
      0.0, 1.0, "%.2f", "Adjust H Compress", 0.0, VI_ON_BRD, dis)
    local after_x, after_y = reaper.ImGui_GetCursorScreenPos(ctx)
    local bottom = row1_sy + ILL_H_GRAPH + 4
    if after_y < bottom then
      reaper.ImGui_SetCursorScreenPos(ctx, after_x, bottom)
    end
  end

  -- ── Row 2: Pivot slider | Anchor knob (violet) ───────────────
  local row2_sy = select(2, reaper.ImGui_GetCursorScreenPos(ctx))
  reaper.ImGui_BeginGroup(ctx)
  modSlider(ctx,env,"skew_pivot","Pivot",
    function() return S.skew_pivot end, function(v) S.skew_pivot=v end,
    0.0, 1.0, "%.2f", sld_w, "Adjust Skew Pivot", 0.0, dis)
  reaper.ImGui_EndGroup(ctx)
  reaper.ImGui_SameLine(ctx, 0, 6)
  do
    local right_sx2, right_sy2 = reaper.ImGui_GetCursorScreenPos(ctx)
    local knob_cx2 = right_sx2 + math.floor((ill_w - KNOB_W) * 0.5)
    reaper.ImGui_SetCursorScreenPos(ctx, knob_cx2, right_sy2)
    modKnobAccent(ctx,env,"h_anchor","Anchor",
      function() return S.h_anchor end, function(v) S.h_anchor=v end,
      0.0, 1.0, "%.2f", "Adjust Anchor", 0.0, VI_ON_BRD, dis)
    local after_x2, after_y2 = reaper.ImGui_GetCursorScreenPos(ctx)
    local bottom2 = row2_sy + ILL_H_GRAPH + 4
    if after_y2 < bottom2 then
      reaper.ImGui_SetCursorScreenPos(ctx, after_x2, bottom2)
    end
  end

  -- ── Combined timing graph ─────────────────────────────────────
  local ig_x, ig_y = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_InvisibleButton(ctx, "##ill_timing", avw, ILL_H_GRAPH)
  illTiming(dl, ig_x, ig_y, avw, ILL_H_GRAPH,
    S.freq_skew, S.skew_pivot, S.h_compress, S.h_anchor)
  if dis then
    reaper.ImGui_DrawList_AddRectFilled(dl, ig_x, ig_y, ig_x+avw, ig_y+ILL_H_GRAPH,
      T.hx(T.C_BG_PANEL, 0.65), 3)
  end

  -- ── Reset All Modifiers ───────────────────────────────────────
  reaper.ImGui_Dummy(ctx, avw, 4)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   6)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx("#581C08"))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx("#7A2A0A"))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx("#9A3A10"))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx("#C04020", 0.6))
  if reaper.ImGui_Button(ctx, "Reset All Modifiers", avw, 26) then
    if has then
      S.resetModifiers()
      Logic.applyModifiers(env)
      Logic.commitUndo("Reset All Modifiers")
    end
  end
  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx, 2)
end

-- drawSwingSection is now empty (swing is drawn inside drawTimingSection).
-- Kept as a stub so main entry point doesn't need changing.
function M.drawSwingSection(ctx, env)
  -- intentionally empty — swing is part of drawTimingSection
end

-- ── Reset _mod_prev when new ref captured ─────────────────────
-- Called from main entry point before drawing modifier sections.
function M.onNewRef(has_ref)
  if has_ref and not _prev_had_ref then _mod_prev = {} end
  _prev_had_ref = has_ref
end

-- ── CONTEXT panel ─────────────────────────────────────────────
function M.drawContextPanel(ctx, dl)
  local avw    = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local fh     = reaper.ImGui_GetTextLineHeight(ctx)
  local ph     = fh + 8
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+avw, sy+ph, T.hx(T.C_INFO, 0.07), 4)

  local env  = reaper.GetSelectedEnvelope(0)
  local line, ic_col
  if not env then
    line   = "⚠  Select an envelope lane"
    ic_col = T.hx(T.C_INFO, 0.80)
  else
    local _, ename  = reaper.GetEnvelopeName(env)
    local n_main    = reaper.CountEnvelopePointsEx(env, -1)
    local sel_cnt   = 0
    for i = 0, n_main-1 do
      local ok, _, _, _, _, sel = reaper.GetEnvelopePointEx(env, -1, i)
      if ok and sel then sel_cnt = sel_cnt+1 end
    end
    local sel_ais = 0
    for i = 0, reaper.CountAutomationItems(env)-1 do
      if reaper.GetSetAutomationItemInfo(env,i,"D_UISEL",0,false) > 0 then sel_ais=sel_ais+1 end
    end
    local ref_info = ""
    if S.ref_entries and #S.ref_entries > 0 then
      local c=0; for _, e in ipairs(S.ref_entries or {}) do c=c+#e.pts end
      ref_info = string.format("  [%d pts captured]", c)
    end
    local conv_tag = ""
    line   = string.format("▶  %s%s  |  %d sel pts  /  %d AI sel%s",
      ename, conv_tag, sel_cnt, sel_ais, ref_info)
    ic_col = T.hx(T.C_INFO, 0.90)
  end
  local lw = reaper.ImGui_CalcTextSize(ctx, line)
  reaper.ImGui_DrawList_AddText(dl, sx+(avw-lw)*0.5, sy+(ph-fh)*0.5, ic_col, line)
  reaper.ImGui_Dummy(ctx, avw, ph)
end

-- ── STATUS BAR ────────────────────────────────────────────────
function M.drawStatusBar(ctx, dl)
  Widgets.drawStatusBar(ctx, dl)
end

return M