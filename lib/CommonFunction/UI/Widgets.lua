-- ============================================================
--   Widgets.lua
--   Reusable, stateless ImGui drawing components.
--   Every widget owns its full style push/pop cycle.
--   Callers pass data in; widgets return events (booleans/strings).
-- ============================================================

local M = {}

local Theme  = require("Theme")
local Logger = require("Logger")
local T      = Theme

-- ── Palette combo / section (violet) ─────────────────────────
local VI_HOV = "#5C3DC8"
local VI_BG  = "#4A32A8"

-- ── Section separator ─────────────────────────────────────────
-- Standard separator: label + horizontal line.
-- alpha: [0,1] for conditional section fades (default 1.0).
function M.drawSectionSep(ctx, dl, label, alpha)
  alpha = alpha or 1.0
  local function apS(col)
    if alpha >= 0.999 then return col end
    return (col & 0xFFFFFF00) | math.floor((col & 0xFF) * alpha + 0.5)
  end
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local sw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  reaper.ImGui_DrawList_AddText(dl, sx + 4, sy, apS(T.hx("#FFFFFF", 0.55)), label)
  reaper.ImGui_Dummy(ctx, 1, 9)
  local lx, ly = reaper.ImGui_GetCursorScreenPos(ctx)
  reaper.ImGui_DrawList_AddLine(dl, lx, ly, lx + sw, ly, apS(T.hx("#FFFFFF", 0.18)))
  reaper.ImGui_Dummy(ctx, 1, 2)
end

-- ── Status bar ────────────────────────────────────────────────
-- Common status bar: reads Logger, blinks red on error.
local _sb_err_t   = nil
local _sb_prev_ok = true

local BLINK_DUR = 4.0
local function _warnAlpha(t)
  if not t then return 1.0 end
  local e = reaper.time_precise() - t
  if e >= BLINK_DUR then return 1.0 end
  local fade = 1.0 - e / BLINK_DUR
  local p    = (math.sin(e * math.pi * 2 * 1.4) + 1) * 0.5
  return 1.0 - (1.0 - 0.38) * (1 - p) * fade
end

function M.drawStatusBar(ctx, dl)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local sw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  reaper.ImGui_DrawList_AddRectFilled(dl, sx - 8, sy, sx + sw + 8, sy + 22, T.hx(T.C_BG_MAIN))
  reaper.ImGui_DrawList_AddRectFilled(dl, sx - 8, sy, sx + sw + 8, sy + 1,  T.hx(T.C_BORDER))
  local msg, is_ok = Logger.get()
  local txt_col
  if is_ok then
    if not _sb_prev_ok then _sb_err_t = nil ; _sb_prev_ok = true end
    txt_col = T.hx(T.C_INFO)
  else
    if _sb_prev_ok then _sb_err_t = reaper.time_precise() ; _sb_prev_ok = false end
    txt_col = T.hx("#FF6060", _warnAlpha(_sb_err_t))
  end
  local fh = reaper.ImGui_GetTextLineHeight(ctx)
  reaper.ImGui_DrawList_AddText(dl, sx, sy + (22 - fh) * 0.5, txt_col, msg)
  reaper.ImGui_Dummy(ctx, 1, 22)
end

-- ── Combo style (violet) ──────────────────────────────────────
-- Uniform ImGui style for BeginCombo across all tools.
-- Call pushComboStyle before BeginCombo, popComboStyle after EndCombo.
function M.pushComboStyle(ctx)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(),   4)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),         T.hx(T.C_BG_PANEL2))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),  T.hx(VI_HOV, 0.38))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgActive(),   T.hx(VI_BG,  0.65))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),            T.hx(T.C_CFG_BASE))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),          T.hx(T.C_BORDER, 0.35))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),         T.hx(T.C_BG_MAIN))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Header(),          T.hx(VI_BG,  0.65))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderHovered(),   T.hx(VI_HOV, 0.42))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_HeaderActive(),    T.hx(VI_HOV, 0.60))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),          T.hx(T.C_BG_PANEL2))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(),   T.hx(VI_HOV, 0.55))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),    T.hx(VI_BG,  0.80))
end

function M.popComboStyle(ctx)
  reaper.ImGui_PopStyleColor(ctx, 12)
  reaper.ImGui_PopStyleVar(ctx,   2)
end

-- ── Graph background ─────────────────────────────────────────

-- Draws a filled rect + grid lines for a graph region.
-- n_div: number of grid divisions (default 4).
function M.drawGraphBG(dl, px, py, pw, ph, bg_col, n_div)
  n_div = n_div or 4
  reaper.ImGui_DrawList_AddRectFilled(dl, px, py, px+pw, py+ph, bg_col)
  local gc = T.hx("#FFFFFF", 0.06)
  for i = 0, n_div do
    reaper.ImGui_DrawList_AddLine(dl, px + pw*i/n_div, py,    px + pw*i/n_div, py+ph, gc)
    reaper.ImGui_DrawList_AddLine(dl, px,              py + ph*i/n_div,
                                      px+pw,           py + ph*i/n_div, gc)
  end
end

-- ── Curve drawing primitives ─────────────────────────────────

-- Draws a polyline from a flat [{number}] array of values in [0,1].
-- Used for mini-graph display.
function M.drawCurve(dl, px, py, pw, ph, vals, color, thick)
  if #vals < 2 then return end
  local lw = thick and 2.0 or 1.2
  for i = 2, #vals do
    local x1 = px + pw * (i - 2) / (#vals - 1)
    local y1 = py + ph - ph * math.max(0, math.min(1, vals[i-1]))
    local x2 = px + pw * (i - 1) / (#vals - 1)
    local y2 = py + ph - ph * math.max(0, math.min(1, vals[i]))
    reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, color, lw)
  end
end

-- Draws a polyline from a [{tn, v}] point list.
-- Used for the main morphed-curve display.
function M.drawCurvePts(dl, px, py, pw, ph, pts, color, thick)
  if #pts < 2 then return end
  local lw   = thick or 2.0
  local toY  = function(v) return py + ph - math.max(0, math.min(1, v)) * ph end
  local prev_x, prev_y
  for _, sp in ipairs(pts) do
    local fx = px + sp.tn * pw
    local fy = toY(sp.v)
    if prev_x then
      reaper.ImGui_DrawList_AddLine(dl, prev_x, prev_y, fx, fy, color, lw)
    end
    prev_x, prev_y = fx, fy
  end
end

-- Draws shapeFit control-point dots and a point-count label.
function M.drawFittedDots(ctx, dl, px, py, pw, ph, pts, dot_color)
  if #pts < 2 then return end
  local toY = function(v) return py + ph - math.max(0, math.min(1, v)) * ph end
  for _, fp in ipairs(pts) do
    reaper.ImGui_DrawList_AddCircleFilled(dl,
      px + fp.tn * pw, toY(fp.v), 2.0, dot_color)
  end
  local pts_lbl = string.format("%d pts", #pts)
  local tw      = reaper.ImGui_CalcTextSize(ctx, pts_lbl)
  local fh      = reaper.ImGui_GetTextLineHeight(ctx)
  local lx      = px + pw - tw - 7
  local ly      = py + ph - fh - 5
  reaper.ImGui_DrawList_AddRectFilled(dl, lx-3, ly-1, lx+tw+3, ly+fh+1,
    T.hx(T.C_BG_MAIN, 0.82), 2)
  reaper.ImGui_DrawList_AddText(dl, lx, ly, T.hx(T.C_TXT_SEC, 0.92), pts_lbl)
end

-- Draws Y-axis reference lines (0% / 50% / 100%) and labels.
function M.drawYLabels(ctx, dl, px, py, pw, ph)
  local fh = reaper.ImGui_GetTextLineHeight(ctx)
  local lm, vm = 7, 5

  reaper.ImGui_DrawList_AddLine(dl, px, py,        px+pw, py,        T.hx("#FFFFFF", 0.20), 1.0)
  reaper.ImGui_DrawList_AddLine(dl, px, py+ph*0.5, px+pw, py+ph*0.5, T.hx("#888888", 0.20), 1.0)
  reaper.ImGui_DrawList_AddLine(dl, px, py+ph,     px+pw, py+ph,     T.hx("#FFFFFF", 0.20), 1.0)

  local labels = {
    { txt="100%", y = py + vm },
    { txt="50%",  y = py + ph*0.5 - fh*0.5 },
    { txt="0%",   y = py + ph - fh - vm },
  }
  for _, lb in ipairs(labels) do
    local tw = reaper.ImGui_CalcTextSize(ctx, lb.txt)
    reaper.ImGui_DrawList_AddRectFilled(dl,
      px+lm-3, lb.y-1, px+lm+tw+3, lb.y+fh+1, T.hx(T.C_BG_MAIN, 0.82), 2)
    reaper.ImGui_DrawList_AddText(dl, px+lm, lb.y, T.hx("#9AA4B2", 0.88), lb.txt)
  end
end

-- ── Mini-graph (source slot) ─────────────────────────────────

-- Draws the source slot mini-graph. brd_only = true when the slot is empty.
function M.drawMiniGraph(dl, px, py, pw, ph, vals, slot_n, brd_only)
  local is1 = (slot_n == 1)
  local bg_col  = is1 and T.hx(T.C_AI1_BG)         or T.hx(T.C_AI2_BG)
  local brd_col = is1 and T.hx(T.C_AI1_SEL, 0.35)  or T.hx(T.C_AI2_SEL, 0.35)
  local cv_r    = is1 and 0.2  or 0.40
  local cv_g    = is1 and 0.3  or 0.30
  local cv_b    = is1 and 0.5  or 0.60

  reaper.ImGui_DrawList_AddRectFilled(dl, px, py, px+pw, py+ph, bg_col)
  local gc = T.hx("#FFFFFF", 0.05)
  for i = 0, 3 do
    reaper.ImGui_DrawList_AddLine(dl, px + pw*i/3, py,    px + pw*i/3, py+ph, gc)
    reaper.ImGui_DrawList_AddLine(dl, px,          py + ph*i/3, px+pw, py + ph*i/3, gc)
  end

  if not brd_only and #vals >= 2 then
    M.drawCurve(dl, px, py, pw, ph, vals, T.rgba(cv_r, cv_g, cv_b), false)
  end
  reaper.ImGui_DrawList_AddRect(dl, px, py, px+pw, py+ph, brd_col, 0, 0, 1.0)
end

-- ── Morph bar (draggable vertical line in main graph) ────────

-- Persistent anchor for Ctrl precision drag on the morph bar.
-- Stores { mode, mx, val } while a Ctrl drag is active.
local _bar_drag_start = nil

-- Draws and manages the draggable morph position bar.
-- Supports normal drag (direct position) and Ctrl drag (0.05x precision).
-- Returns (new_morph, still_dragging).
function M.drawMorphBar(ctx, dl, px, py, pw, ph, morph, dragging, slider_active)
  local mx          = px + morph * pw
  local mouse_x, mouse_y = reaper.ImGui_GetMousePos(ctx)
  local bar_hovered = (mouse_x >= mx-8 and mouse_x <= mx+8
                   and mouse_y >= py  and mouse_y <= py+ph)

  if bar_hovered and reaper.ImGui_IsMouseClicked(ctx, 0) then
    dragging = true
  end
  if dragging then
    if reaper.ImGui_IsMouseDown(ctx, 0) then
      local ctrl = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
      if ctrl then
        -- Precision mode: anchor on first Ctrl frame, then scale movement by 0.05x
        if not _bar_drag_start or _bar_drag_start.mode ~= "ctrl" then
          _bar_drag_start = { mode = "ctrl", mx = mouse_x, val = morph }
        end
        local ds = _bar_drag_start
        morph = math.max(0, math.min(1, ds.val + (mouse_x - ds.mx) / pw * 0.05))
      else
        _bar_drag_start = nil
        morph = math.max(0, math.min(1, (mouse_x - px) / pw))
      end
      mx = px + morph * pw
    else
      dragging        = false
      _bar_drag_start = nil
    end
  end

  local lit   = dragging or slider_active
  local thick = lit and 4.0 or (bar_hovered and 2.5 or 1.5)
  local bar_col
  if lit           then bar_col = T.hx(T.C_MORPH_GRAB, 1.0)
  elseif bar_hovered then bar_col = T.hx(T.C_MORPH_GRAB, 0.90)
  else                 bar_col = T.hx(T.C_MORPH_GRAB, 0.55) end

  reaper.ImGui_DrawList_AddLine(dl, mx, py, mx, py+ph, bar_col, thick)

  local tri_s = lit and 8 or (bar_hovered and 7 or 5)
  reaper.ImGui_DrawList_AddTriangleFilled(dl,
    mx - tri_s, py+ph-1,
    mx + tri_s, py+ph-1,
    mx,         py+ph - tri_s*1.4,
    bar_col)

  if bar_hovered or lit then
    local cur = reaper.ImGui_MouseCursor_ResizeEW and reaper.ImGui_MouseCursor_ResizeEW() or 3
    reaper.ImGui_SetMouseCursor(ctx, cur)
  end

  return morph, dragging
end

-- ── Status pill ──────────────────────────────────────────────

-- Draws a rounded-rect status badge with centered text.
function M.drawStatusPill(ctx, dl, sx, sy, sw, text, col, bg_col, height)
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+sw, sy+height, bg_col, 4)
  if text and text ~= "" then
    local tw = reaper.ImGui_CalcTextSize(ctx, text)
    local fh = reaper.ImGui_GetTextLineHeight(ctx)
    reaper.ImGui_DrawList_AddText(dl,
      sx + (sw - tw) * 0.5, sy + (height - fh) * 0.5, col, text)
  end
end

-- ── Source slot button ───────────────────────────────────────
-- A self-contained, three-state button for the capture workflow.
-- slot_n : 1 or 2 — controls the color scheme
-- state  : "empty" | "waiting" | "captured"
-- badge  : "AI" | "ENV" | nil  — shown when state == "captured"
-- avail_w, bh : dimensions
-- Returns: "capture" | "cancel" | "recapture" | "clear" | nil

local function slotColorRGB(slot_n)
  -- Base RGB for slot 1 (blue) and slot 2 (purple)
  if slot_n == 1 then return 0.055, 0.647, 0.914
  else                return 0.545, 0.361, 0.965 end
end

local function pulse(freq_hz)
  return (math.sin(reaper.time_precise() * math.pi * 2 * freq_hz) + 1) * 0.5
end

function M.drawSourceSlotButton(ctx, dl, slot_n, state, badge, avail_w, bh)
  local cr, cg, cb = slotColorRGB(slot_n)
  local action = nil

  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(),   8)
  reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 1.5)

  if state == "captured" then
    -- ── Captured: show badge + "Recapture N" + clear button ──
    local cbw = avail_w - 36
    badge = badge or "AI"

    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.rgba(cr*0.25,cg*0.25,cb*0.25))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.rgba(cr*0.40,cg*0.40,cb*0.40))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.rgba(cr*0.55,cg*0.55,cb*0.55))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.rgba(math.min(1,cr+0.4),math.min(1,cg+0.4),math.min(1,cb+0.4)))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.rgba(cr*0.8,cg*0.8,cb*0.8))

    if reaper.ImGui_Button(ctx, "##cap_disp"..slot_n, cbw, bh) then
      action = "recapture"
    end
    do
      local bx, by  = reaper.ImGui_GetItemRectMin(ctx)
      local fh      = reaper.ImGui_GetTextLineHeight(ctx)
      local bw      = reaper.ImGui_CalcTextSize(ctx, badge)
      local pad_b   = 6
      local badge_c = T.rgba(cr, cg, cb, 0.85)
      reaper.ImGui_DrawList_AddRectFilled(dl,
        bx+6, by+(bh-fh)*0.5-2, bx+6+bw+pad_b*2, by+(bh+fh)*0.5+2, badge_c, 4)
      reaper.ImGui_DrawList_AddText(dl, bx+6+pad_b, by+(bh-fh)*0.5, T.hx(T.C_BG_MAIN), badge)
      local lbl  = "Recapture " .. slot_n
      local lw   = reaper.ImGui_CalcTextSize(ctx, lbl)
      local rx   = bx+6+bw+pad_b*2+8
      local rw   = cbw-(rx-bx)-6
      reaper.ImGui_DrawList_AddText(dl, rx+(rw-lw)*0.5, by+(bh-fh)*0.5,
        T.rgba(math.min(1,cr+0.4),math.min(1,cg+0.4),math.min(1,cb+0.4)), lbl)
    end
    reaper.ImGui_PopStyleColor(ctx, 5)

    -- Clear button
    reaper.ImGui_SameLine(ctx, 0, 4)
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(), 11)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx("#3A1A1A"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx("#7A2020"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx("#962424"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx("#FF8080"))
    if reaper.ImGui_Button(ctx, "✕##cl"..slot_n, 28, bh) then
      action = "clear"
    end
    reaper.ImGui_PopStyleColor(ctx, 4)
    reaper.ImGui_PopStyleVar(ctx)

  elseif state == "waiting" then
    -- ── Waiting: pulsing "select…" button, click cancels ─────
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.rgba(0.65, 0.35, 0.10))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.rgba(0.80, 0.30, 0.15))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.rgba(0.80, 0.30, 0.15))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.rgba(1.0, 0.85, 0.70))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.rgba(0.90, 0.40, 0.20))

    if reaper.ImGui_Button(ctx, "##capwait"..slot_n, avail_w, bh) then
      action = "cancel"
    end
    do
      local bx, by  = reaper.ImGui_GetItemRectMin(ctx)
      local lbl     = "Select AI or env. points…"
      local fh      = reaper.ImGui_GetTextLineHeight(ctx)
      local lbl_w   = reaper.ImGui_CalcTextSize(ctx, lbl)
      local txt_col = T.rgba(1.0, 0.85, 0.70, 0.55 + 0.45 * pulse(1.2))
      reaper.ImGui_DrawList_AddText(dl,
        bx + (avail_w - lbl_w) * 0.5, by + (bh - fh) * 0.5, txt_col, lbl)
    end
    reaper.ImGui_PopStyleColor(ctx, 5)

  else
    -- ── Empty: "Capture Source N" button with circle+cross icon ──
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.rgba(cr*0.15,cg*0.15,cb*0.15))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.rgba(cr*0.40,cg*0.40,cb*0.40))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.rgba(cr*0.55,cg*0.55,cb*0.55))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.rgba(math.min(1,cr+0.5),math.min(1,cg+0.5),math.min(1,cb+0.5)))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.rgba(cr*0.7,cg*0.7,cb*0.7))

    if reaper.ImGui_Button(ctx, "##cap"..slot_n, avail_w, bh) then
      action = "capture"
    end
    do
      local bx, by   = reaper.ImGui_GetItemRectMin(ctx)
      local bw, bh2  = reaper.ImGui_GetItemRectSize(ctx)
      local ic_r     = 10
      local ic_w     = ic_r * 2
      local gap      = 14
      local ic_col   = T.rgba(math.min(1,cr+0.3),math.min(1,cg+0.3),math.min(1,cb+0.3), 0.80)
      local txt_col  = T.rgba(math.min(1,cr+0.5),math.min(1,cg+0.5),math.min(1,cb+0.5))
      local lbl      = "Capture Source " .. slot_n
      local lbl_w    = reaper.ImGui_CalcTextSize(ctx, lbl)
      local fh       = reaper.ImGui_GetTextLineHeight(ctx)

      local total_block_w = ic_w + gap + lbl_w
      local text_x        = bx + (bw - total_block_w) * 0.5 + ic_w + gap
      local icon_center_x = bx + (text_x - bx - ic_w) * 0.5 + ic_r
      local cy            = by + bh2 * 0.5
      local arm           = math.floor(ic_r * 0.6)

      reaper.ImGui_DrawList_AddCircle(dl, math.floor(icon_center_x), math.floor(cy), ic_r, ic_col, 24, 1.8)
      reaper.ImGui_DrawList_AddLine(dl, math.floor(icon_center_x)-arm, math.floor(cy),
                                        math.floor(icon_center_x)+arm, math.floor(cy), ic_col, 1.8)
      reaper.ImGui_DrawList_AddLine(dl, math.floor(icon_center_x), math.floor(cy)-arm,
                                        math.floor(icon_center_x), math.floor(cy)+arm, ic_col, 1.8)
      reaper.ImGui_DrawList_AddText(dl, text_x, by+(bh2-fh)*0.5, txt_col, lbl)
    end
    reaper.ImGui_PopStyleColor(ctx, 5)
  end

  reaper.ImGui_PopStyleVar(ctx, 2)
  return action
end

-- ── Insert buttons ───────────────────────────────────────────
-- Shared style helper (internal).
local function pushInsertStyle(ctx, enabled)
  if enabled then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BTN_INS_PRESS))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_BTN_INS_BASE))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_BTN_INS_HOV))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx("#FFFFFF"))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_BTN_INS_HOV))
  else
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BTN_INS_BG))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_BTN_INS_BG))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_BTN_INS_BG))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_DISABLED))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_BTN_INS_PRESS, 0.4))
  end
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), 1.5)
end

-- Draws the "ENVELOPE POINTS" insert button.
-- Returns true if clicked while enabled.
function M.drawEnvPointsButton(ctx, dl, width, height, enabled)
  pushInsertStyle(ctx, enabled)
  local pressed = reaper.ImGui_Button(ctx, "##gen_env", width, height)
  do
    local bx, by   = reaper.ImGui_GetItemRectMin(ctx)
    local bw, bh   = reaper.ImGui_GetItemRectSize(ctx)
    local ic_col   = T.hx(enabled and "#FFFFFF" or T.C_DISABLED, enabled and 0.9 or 0.45)
    local lbl      = "ENVELOPE POINTS"
    local lbl_w, lbl_h = reaper.ImGui_CalcTextSize(ctx, lbl)
    local ic_w, gap, dot_r = 20, 12, 2.2

    local total_block_w = ic_w + gap + lbl_w
    local text_x        = bx + (bw - total_block_w) * 0.5 + ic_w + gap
    local icon_start_x  = bx + (text_x - bx - ic_w) * 0.5
    local mid_y         = by + bh * 0.5

    local p1x, p1y = math.floor(icon_start_x + dot_r),        math.floor(mid_y + 3)
    local p2x, p2y = math.floor(icon_start_x + ic_w * 0.33),  math.floor(mid_y - 4)
    local p3x, p3y = math.floor(icon_start_x + ic_w * 0.66),  math.floor(mid_y + 4)
    local p4x, p4y = math.floor(icon_start_x + ic_w - dot_r), math.floor(mid_y - 2)
    reaper.ImGui_DrawList_AddLine(dl, p1x, p1y, p2x, p2y, ic_col, 1.5)
    reaper.ImGui_DrawList_AddLine(dl, p2x, p2y, p3x, p3y, ic_col, 1.5)
    reaper.ImGui_DrawList_AddLine(dl, p3x, p3y, p4x, p4y, ic_col, 1.5)
    reaper.ImGui_DrawList_AddCircleFilled(dl, p1x, p1y, dot_r, ic_col)
    reaper.ImGui_DrawList_AddCircleFilled(dl, p2x, p2y, dot_r, ic_col)
    reaper.ImGui_DrawList_AddCircleFilled(dl, p3x, p3y, dot_r, ic_col)
    reaper.ImGui_DrawList_AddCircleFilled(dl, p4x, p4y, dot_r, ic_col)
    reaper.ImGui_DrawList_AddText(dl, text_x, mid_y - lbl_h * 0.5, ic_col, lbl)
  end
  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx)
  return pressed and enabled
end

-- Draws the "AUTOMATION ITEM" insert button.
-- Returns true if clicked while enabled.
function M.drawAutoItemButton(ctx, dl, width, height, enabled)
  pushInsertStyle(ctx, enabled)
  local pressed = reaper.ImGui_Button(ctx, "##gen_ai", width, height)
  do
    local bx, by   = reaper.ImGui_GetItemRectMin(ctx)
    local bw, bh   = reaper.ImGui_GetItemRectSize(ctx)
    local ic_col   = T.hx(enabled and "#FFFFFF" or T.C_DISABLED, enabled and 0.9 or 0.45)
    local ic_brd   = T.hx(enabled and "#FFFFFF" or T.C_DISABLED, enabled and 0.75 or 0.30)
    local lbl      = "AUTOMATION ITEM"
    local lbl_w, fh = reaper.ImGui_CalcTextSize(ctx, lbl)
    local ic_ow, ic_oh, gap = 28, 14, 12

    local total_block_w = ic_ow + gap + lbl_w
    local text_x        = bx + (bw - total_block_w) * 0.5 + ic_ow + gap
    local icon_start_x  = bx + (text_x - bx - ic_ow) * 0.5
    local mid_y         = by + bh * 0.5

    reaper.ImGui_DrawList_AddRect(dl,
      icon_start_x, mid_y-ic_oh*0.5,
      icon_start_x+ic_ow, mid_y+ic_oh*0.5, ic_brd, 0, 0, 1.5)
    reaper.ImGui_DrawList_AddRectFilled(dl,
      icon_start_x+5, mid_y-2, icon_start_x+ic_ow-5, mid_y+2, ic_col, 0)
    reaper.ImGui_DrawList_AddText(dl, text_x, mid_y - fh*0.5, ic_col, lbl)
  end
  reaper.ImGui_PopStyleColor(ctx, 5)
  reaper.ImGui_PopStyleVar(ctx)
  return pressed and enabled
end

-- ── Shared INSERT panel (LFO + Generator) ────────────────────
-- on_pts / on_ai: callbacks called on click (include undo blocks if needed)
function M.drawInsertPanel(ctx, dl, ctx_info, on_pts, on_ai, extra_cond)
  local avw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local gbw     = math.floor((avw - 6) / 2)
  local gbh     = 38
  local gate    = extra_cond == nil and true or extra_cond
  local can_pts = gate and ctx_info.has_target and (ctx_info.use_ts or ctx_info.is_item_env)
  local can_ai  = can_pts and not ctx_info.is_item_env and not ctx_info.is_tempo_env

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FramePadding(),  10, 8)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(), 8)
  if M.drawEnvPointsButton(ctx, dl, gbw, gbh, can_pts) and on_pts then on_pts() end
  reaper.ImGui_SameLine(ctx, 0, 6)
  if M.drawAutoItemButton(ctx, dl, gbw, gbh, can_ai)   and on_ai  then on_ai()  end
  reaper.ImGui_PopStyleVar(ctx, 2)
end

-- ── Shared CONTEXT panel (LFO + Generator) ───────────────────
-- Displays the target context or a centered warning.
function M.drawSimpleContextPanel(ctx, dl, ctx_info)
  local sw2      = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local sx2, sy2 = reaper.ImGui_GetCursorScreenPos(ctx)
  local fh       = reaper.ImGui_GetTextLineHeight(ctx)
  local pill_h   = fh + 8
  local T        = require("Theme")

  reaper.ImGui_DrawList_AddRectFilled(dl, sx2, sy2, sx2+sw2, sy2+pill_h, T.hx(T.C_INFO, 0.07), 4)

  local ci     = ctx_info
  local ic_col = T.hx(T.C_INFO, 0.80)
  local line   = nil

  if not ci.has_target and not ci.use_ts then
    line = "⚠  Select an item + FX lane, or set a time selection + envelope"
  elseif ci.has_target and ci.is_item_env and not ci.has_target then
    line = "⚠  Item has no visible take FX envelope lane"
  elseif not ci.has_target then
    line = "⚠  Select an envelope lane"
  elseif not ci.use_ts and not ci.is_item_env then
    line = "⚠  Set a time selection"
  else
    local ic_w, pad_l, gap = 14, 10, 6
    local ic_x  = sx2 + pad_l
    local txt_x = ic_x + ic_w + gap
    local cy_ic = sy2 + pill_h * 0.5
    local ts    = 5
    reaper.ImGui_DrawList_AddTriangleFilled(dl,
      ic_x, cy_ic-ts, ic_x, cy_ic+ts, ic_x+ts*1.6, cy_ic, ic_col)
    local tgt = ci.env_name and ci.track_num
      and string.format("TRK_%d › %s  [%.2fs – %.2fs]",
          ci.track_num, ci.env_name, ci.ts_s or 0, ci.ts_e or 0)
      or  (ci.env_name or "?")
    reaper.ImGui_DrawList_AddText(dl, txt_x, sy2 + (pill_h - fh) * 0.5, ic_col, tgt)
  end

  if line then
    local lw = reaper.ImGui_CalcTextSize(ctx, line)
    reaper.ImGui_DrawList_AddText(dl,
      sx2 + (sw2 - lw) * 0.5, sy2 + (pill_h - fh) * 0.5,
      T.hx(T.C_INFO, 0.88), line)
  end
  reaper.ImGui_Dummy(ctx, 1, pill_h)
end

-- ── Violet select palette (shared across all panels) ─────────
M.VI_BG  = "#4A32A8"  -- active button fill
M.VI_HOV = "#5C3DC8"  -- active button hover
M.VI_BRD = "#7B5CE0"  -- active button border

-- ── Shape icon (segments 0–5 + Bezier text fallback) ─────────
-- Draws a waveform icon centered in (bx, by, bw, bh).
-- shape_id : 0=Linear  1=Square  2=SlowS/E  3=Fast+  4=Fast-  5=Bezier
-- col      : ImU32 color for lines and dots.
function M.drawShapeIcon(dl, ctx, bx, by, bw, bh, shape_id, col)
  if shape_id == 5 then
    local lbl = "Bezier"
    local lw, lh = reaper.ImGui_CalcTextSize(ctx, lbl)
    reaper.ImGui_DrawList_AddText(dl,
      math.floor(bx + (bw - lw) * 0.5),
      math.floor(by + (bh - lh) * 0.5), col, lbl)
    return
  end
  local pad = 5
  local iw  = math.max(4, bw - pad * 2)
  local ih  = math.max(4, bh - pad * 2)
  local ox  = math.floor(bx + pad)
  local oy  = math.floor(by + pad)
  local lw2 = 1.6
  local function Sc(t, v) return ox + t * iw, oy + (1 - v) * ih end
  local function seg(t1, v1, t2, v2)
    local x1, y1 = Sc(t1, v1) ; local x2, y2 = Sc(t2, v2)
    reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, lw2)
  end
  local function dot(t, v) local x, y = Sc(t, v) ; reaper.ImGui_DrawList_AddCircleFilled(dl, x, y, 2.0, col) end
  local function smpl(fn, n)
    local pv = fn(0)
    for i = 1, n do local t = i / n ; local v = fn(t) ; seg((i-1)/n, pv, t, v) ; pv = v end
  end
  if     shape_id == 0 then seg(0, 0, 1, 1) ; dot(0, 0) ; dot(1, 1)
  elseif shape_id == 1 then
    local j = 0.42 ; seg(0, 0.08, j, 0.08)
    local x1, y1 = Sc(j, 0.08) ; local x2, y2 = Sc(j, 0.92)
    reaper.ImGui_DrawList_AddLine(dl, x1, y1, x2, y2, col, lw2)
    seg(j, 0.92, 1, 0.92) ; dot(0, 0.08) ; dot(1, 0.92)
  elseif shape_id == 2 then smpl(function(t) return (1 - math.cos(t * math.pi)) * 0.5 end, 32) ; dot(0, 0) ; dot(1, 1)
  elseif shape_id == 3 then smpl(function(t) return 1 - (1-t)*(1-t) end, 28) ; dot(0, 0) ; dot(1, 1)
  elseif shape_id == 4 then smpl(function(t) return t * t end, 28) ; dot(0, 0) ; dot(1, 1)
  end
end

-- ── Generic VI-palette select button row ─────────────────────
-- Draws N equal-width select buttons using the violet active palette.
-- items    : [{ id, label [, get_label] [, draw_fn] [, on_click] }]
--   id        : (required) selection value
--   label     : static text drawn centered  (empty = icon-only via draw_fn)
--   get_label : optional function() → string  (overrides label)
--   draw_fn   : optional function(dl, ctx, bx, by, bw, bh, active)
--   on_click  : optional function()  (custom action, skips active tracking)
-- active_id : currently selected id
-- opts (all optional):
--   bh=26  gap=3  rounding=4  border=1.0  prefix="##vbr"
--   disabled=false  → blocks selection + draws dim overlay over each button
-- Returns new active_id.
function M.drawViButtonRow(ctx, dl, items, active_id, opts)
  local bh       = opts and opts.bh       or 26
  local gap      = opts and opts.gap      or 3
  local rounding = opts and opts.rounding or 4
  local border   = opts and opts.border   or 1.0
  local prefix   = opts and opts.prefix   or "##vbr"
  local disabled = opts and opts.disabled or false

  local n   = #items
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local bw  = math.floor((avw - gap * (n - 1)) / n)
  local fh  = reaper.ImGui_GetTextLineHeight(ctx)
  local new_active = active_id

  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameRounding(),   rounding)
  reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_FrameBorderSize(), border)

  for i, item in ipairs(items) do
    local active = (active_id == item.id)
    if active then
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(M.VI_BG))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(M.VI_BG))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(M.VI_HOV))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(M.VI_BRD))
    else
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(T.C_CFG_SEL))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(T.C_CFG_SEL))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_CFG_BASE))
      reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(T.C_BORDER))
    end

    if reaper.ImGui_Button(ctx, prefix .. i, bw, bh) and not disabled then
      if item.on_click then item.on_click()
      else               new_active = item.id end
    end

    do
      local bx2, by2 = reaper.ImGui_GetItemRectMin(ctx)
      local bw2, bh2 = reaper.ImGui_GetItemRectSize(ctx)
      if item.draw_fn then
        item.draw_fn(dl, ctx, bx2, by2, bw2, bh2, active)
      else
        local text = (item.get_label and item.get_label()) or item.label or ""
        if text ~= "" then
          local tc = disabled                  and T.hx(T.C_DISABLED, 0.45)
                     or (active and T.hx(T.C_TXT_PRI) or T.hx(T.C_CFG_BASE, 0.85))
          local tw = reaper.ImGui_CalcTextSize(ctx, text)
          reaper.ImGui_DrawList_AddText(dl,
            math.floor(bx2 + (bw2 - tw) * 0.5),
            math.floor(by2 + (bh2 - fh) * 0.5), tc, text)
        end
      end
      if disabled then
        reaper.ImGui_DrawList_AddRectFilled(dl, bx2, by2, bx2+bw2, by2+bh2,
          T.hx(T.C_BG_MAIN, 0.58), rounding)
      end
    end

    reaper.ImGui_PopStyleColor(ctx, 5)
    if i < n then reaper.ImGui_SameLine(ctx, 0, gap) end
  end

  reaper.ImGui_PopStyleVar(ctx, 2)
  return new_active
end

-- ── Knob widget ───────────────────────────────────────────────
-- Circular knob with 270° arc track. Drag vertically to change
-- value; Shift/Ctrl for fine/ultra-fine; double-click to reset.
-- Exported size constants for multi-knob layout.
M.KNOB_D = 28   -- circle diameter (px)
M.KNOB_W = 50   -- widget bounding-box width

local _knob_sld_reset  = {}
local _knob_editing    = {}
local _knob_edit_buf   = {}
local _knob_edit_frame = {}
local _knob_committed  = {}
local _knob_drag_state = {}

local _KNOB_A_MIN   = math.pi * 0.75  -- 135° start (8-o'clock)
local _KNOB_A_RANGE = math.pi * 1.5   -- 270° sweep CW

local function _arcLine(dl, cx, cy, r, a1, a2, col, thick)
  reaper.ImGui_DrawList_PathArcTo(dl, cx, cy, r, a1, a2)
  reaper.ImGui_DrawList_PathStroke(dl, col, 0, thick)
end

-- drawKnob(ctx, id, label, value, vmin, vmax, fmt, disabled, default_val)
-- Returns (new_value, is_active).
function M.drawKnob(ctx, id, label, value, vmin, vmax, fmt, disabled, default_val)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local fh  = reaper.ImGui_GetTextLineHeight(ctx)
  local r   = math.floor(M.KNOB_D * 0.5)
  local KW, KD = M.KNOB_W, M.KNOB_D

  reaper.ImGui_BeginGroup(ctx)

  -- Label
  local lsx, lsy = reaper.ImGui_GetCursorScreenPos(ctx)
  local lw  = label ~= "" and reaper.ImGui_CalcTextSize(ctx, label) or 0
  local lc  = disabled and T.hx(T.C_DISABLED) or T.hx(T.C_TXT_PRI, 0.80)
  if label ~= "" then
    reaper.ImGui_DrawList_AddText(dl, lsx + math.floor((KW - lw) * 0.5), lsy, lc, label)
  end
  reaper.ImGui_Dummy(ctx, KW, fh - 2)

  -- Invisible hit area
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_InvisibleButton(ctx, "##knob_" .. id, KW, KD)
  local hov = reaper.ImGui_IsItemHovered(ctx)
  local act = reaper.ImGui_IsItemActive(ctx)
  if disabled then reaper.ImGui_EndDisabled(ctx) end

  local bx, by = reaper.ImGui_GetItemRectMin(ctx)
  local cx = math.floor(bx + KW * 0.5)
  local cy = math.floor(by + KD * 0.5)

  local edit_key = "knb_" .. id
  local nv = _knob_committed[edit_key] or value
  _knob_committed[edit_key] = nil

  if _knob_sld_reset[edit_key] then
    if not reaper.ImGui_IsMouseDown(ctx, 0) then _knob_sld_reset[edit_key] = nil end
  elseif hov and not disabled and default_val ~= nil and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    nv = default_val ; _knob_sld_reset[edit_key] = true
  elseif act and not disabled then
    if not _knob_drag_state[id] then
      local my = select(2, reaper.ImGui_GetMousePos(ctx))
      _knob_drag_state[id] = { y = my, v = nv }
    end
    local my    = select(2, reaper.ImGui_GetMousePos(ctx))
    local ctrl  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    local dy    = _knob_drag_state[id].y - my
    local sens  = (ctrl and shift) and 1920.0 or shift and 960.0 or ctrl and 1920.0 or 120.0
    nv = _knob_drag_state[id].v + dy * (vmax - vmin) / sens
  end
  if not act then _knob_drag_state[id] = nil end
  nv = math.max(vmin, math.min(vmax, nv))

  local norm  = (vmax > vmin) and ((nv - vmin) / (vmax - vmin)) or 0
  local a_cur = _KNOB_A_MIN + norm * _KNOB_A_RANGE
  local r_arc = r - 2

  -- Track arcs (groove → track → filled)
  _arcLine(dl, cx, cy, r_arc, _KNOB_A_MIN, _KNOB_A_MIN + _KNOB_A_RANGE, T.hx(T.C_BG_MAIN), 5.0)
  _arcLine(dl, cx, cy, r_arc, _KNOB_A_MIN, _KNOB_A_MIN + _KNOB_A_RANGE,
    disabled and T.hx(T.C_BG_PANEL2) or T.hx(T.C_SLD_TRK), 3.0)
  local fill_c = disabled and T.hx(T.C_DISABLED, 0.50)
    or (act and T.hx(T.C_MORPH_GRAB_HV, 0.90) or (hov and T.hx(T.C_MORPH_GRAB, 0.80) or T.hx(T.C_MORPH_GRAB, 0.65)))
  if not disabled and norm > 0.001 then
    _arcLine(dl, cx, cy, r_arc, _KNOB_A_MIN, a_cur, fill_c, 3.0)
  end

  -- Body circle
  local r_body = r - 6
  reaper.ImGui_DrawList_AddCircleFilled(dl, cx, cy, r_body,
    disabled and T.hx(T.C_BG_MAIN) or T.hx(T.C_BG_PANEL2))
  local brd_c = disabled and T.hx(T.C_BORDER, 0.40)
    or (hov and T.hx(T.C_MORPH_GRAB, 0.55) or T.hx(T.C_BORDER, 0.60))
  reaper.ImGui_DrawList_AddCircle(dl, cx, cy, r_body, brd_c, 0, 1.0)

  -- Indicator dot on arc edge
  if not disabled then
    local ix = cx + math.cos(a_cur) * (r_arc - 1)
    local iy = cy + math.sin(a_cur) * (r_arc - 1)
    reaper.ImGui_DrawList_AddCircleFilled(dl, ix, iy, 3.2, fill_c)
  end

  -- Value text / inline InputText (double-click to edit)
  local arc_btm = math.floor(cy + math.sin(_KNOB_A_MIN) * r_arc)
  local vs      = string.format(fmt or "%.2f", nv)
  local vw2     = reaper.ImGui_CalcTextSize(ctx, vs)
  local val_x   = bx + math.floor((KW - vw2) * 0.5)

  if _knob_editing[edit_key] then
    reaper.ImGui_SetCursorScreenPos(ctx, val_x - 5, arc_btm + 1)
    reaper.ImGui_SetNextItemWidth(ctx, vw2 + 10)
    if _knob_edit_buf[edit_key] == nil then _knob_edit_buf[edit_key] = vs end
    _knob_edit_frame[edit_key] = (_knob_edit_frame[edit_key] or 0) + 1
    if _knob_edit_frame[edit_key] == 1 then reaper.ImGui_SetKeyboardFocusHere(ctx) end
    local changed, buf2 = reaper.ImGui_InputText(ctx, "##ed_knb_" .. id, _knob_edit_buf[edit_key])
    if changed then _knob_edit_buf[edit_key] = buf2 end
    local enter = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
               or reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false)
    local clicked_outside = reaper.ImGui_IsMouseClicked(ctx, 0)
                        and not reaper.ImGui_IsItemHovered(ctx)
                        and _knob_edit_frame[edit_key] > 2
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
      _knob_editing[edit_key] = nil ; _knob_edit_buf[edit_key] = nil ; _knob_edit_frame[edit_key] = nil
    elseif enter or clicked_outside then
      local p = tonumber(_knob_edit_buf[edit_key])
      if p then nv = math.max(vmin, math.min(vmax, p)) ; _knob_committed[edit_key] = nv end
      _knob_editing[edit_key] = nil ; _knob_edit_buf[edit_key] = nil ; _knob_edit_frame[edit_key] = nil
    end
  else
    local vc = disabled and T.hx(T.C_DISABLED, 0.50) or T.hx(T.C_TXT_PRI, act and 1.0 or 0.72)
    reaper.ImGui_DrawList_AddText(dl, val_x, arc_btm + 7, vc, vs)
    reaper.ImGui_SetCursorScreenPos(ctx, val_x - 10, arc_btm + 1)
    reaper.ImGui_InvisibleButton(ctx, "##vclick_knb_" .. id, vw2 + 20, fh + 4)
    if not disabled and reaper.ImGui_IsItemHovered(ctx)
        and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      _knob_editing[edit_key] = true ; _knob_edit_buf[edit_key] = vs ; _knob_edit_frame[edit_key] = 0
    end
  end

  reaper.ImGui_EndGroup(ctx)
  return nv, act
end

return M
