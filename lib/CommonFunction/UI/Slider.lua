-- ============================================================
--   CommonFunction/Slider.lua
--   Shared custom DrawList slider (morph-style).
--   Shared by: LFOPanel, RANDPanel, SCULPTPanel.
--
--   Usage:
--     local Slider = require("Slider")
--     local v = Slider.draw(ctx, id, label, value, v_min, v_max, fmt, w,
--                           disabled, is_int, default_val, opts)
--     -- opts = {
--     --   sld_h       = number,  -- slider height (default 24)
--     --   gap         = number,  -- margin between min/max labels and track (default 6)
--     --   alpha       = number,  -- DrawList alpha multiplier (default 1.0)
--     --   anchor_sx   = number,  -- if set, repositions cursor X before label
--     --   return_active = bool,  -- if true, returns (nv, act) instead of nv alone
--     -- }
--     local v = Slider.drawInt(ctx, id, label, value, v_min, v_max, w, disabled, default_val, opts)
--     local v = Slider.drawFloat(ctx, id, label, value, v_min, v_max, fmt, w, disabled, default_val, opts)
--     Slider.drawPair(ctx, avw, gap, fn_a, fn_b)
-- ============================================================

local M = {}

local Theme = require("Theme")
local T     = Theme

-- ── Module-level state (shared across all tools via Lua cache) ───────────
-- Slider IDs must be globally unique (should include a tool prefix).
local _sld_reset      = {}
local _sld_editing    = {}
local _sld_edit_buf   = {}
local _sld_edit_frame = {}
local _sld_committed  = {}
local _sld_drag_start = {}

-- ── draw ─────────────────────────────────────────────────────
-- Retourne new_val (si opts.return_active : new_val, is_active)
function M.draw(ctx, id, label, value, v_min, v_max, fmt, w, disabled, is_int, default_val, opts)
  opts = opts or {}

  local sld_h   = opts.sld_h   or 24
  local gap     = opts.gap     or 6
  local alpha   = opts.alpha   or 1.0
  local anc_sx  = opts.anchor_sx

  -- Alpha wrapper for DrawList colors
  local function hxa(col, a)
    return T.hx(col, (a or 1.0) * alpha)
  end

  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  local fh = reaper.ImGui_GetTextLineHeight(ctx)

  -- X anchor function (LFO: aligned columns)
  local function pin()
    if anc_sx then
      local _, cy = reaper.ImGui_GetCursorScreenPos(ctx)
      reaper.ImGui_SetCursorScreenPos(ctx, anc_sx, cy)
    end
  end

  -- Title centered above the slider
  if label and label ~= "" then
    pin()
    local tw     = reaper.ImGui_CalcTextSize(ctx, label)
    local tx, ty = reaper.ImGui_GetCursorScreenPos(ctx)
    local tc = disabled and hxa(T.C_DISABLED) or hxa(T.C_TXT_PRI, 0.88)
    reaper.ImGui_DrawList_AddText(dl, tx + math.floor((w - tw) * 0.5), ty, tc, label)
    reaper.ImGui_Dummy(ctx, w, fh)
  end

  pin()

  -- Lateral min/max labels (opts.min_label / opts.max_label override the auto value)
  local min_str = opts.min_label or (is_int and tostring(math.floor(v_min))
                          or string.format(fmt or "%.2f", v_min))
  local max_str = opts.max_label or (is_int and tostring(math.floor(v_max))
                          or string.format(fmt or "%.2f", v_max))
  local min_w   = reaper.ImGui_CalcTextSize(ctx, min_str)
  local max_w   = reaper.ImGui_CalcTextSize(ctx, max_str)
  local mar_l   = min_w + gap
  local mar_r   = max_w + gap

  local sx_full, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local sld_w = math.max(20, w - mar_l - mar_r)
  local sx    = sx_full + mar_l

  -- Zone de hit
  if disabled then reaper.ImGui_BeginDisabled(ctx) end
  reaper.ImGui_InvisibleButton(ctx, "##sld_"..id, w, sld_h)
  local hovered = reaper.ImGui_IsItemHovered(ctx)
  local active  = reaper.ImGui_IsItemActive(ctx)
  if disabled then reaper.ImGui_EndDisabled(ctx) end

  -- Value committed from InputText previous frame
  local new_val = _sld_committed[id] or value
  _sld_committed[id] = nil

  if _sld_reset[id] then
    if not reaper.ImGui_IsMouseDown(ctx, 0) then _sld_reset[id] = nil end
  elseif hovered and not disabled and default_val ~= nil
      and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
    new_val = default_val ; _sld_reset[id] = true
  elseif active and not disabled and not _sld_editing[id] then
    local mx, my = reaper.ImGui_GetMousePos(ctx)
    local ctrl   = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
    local shift  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
    if ctrl then
      if not _sld_drag_start[id] or _sld_drag_start[id].mode ~= "ctrl" then
      _sld_drag_start[id] = {mode="ctrl", mx=mx, val=new_val}
    end
      local ds = _sld_drag_start[id]
      new_val = ds.val + ((mx - ds.mx) / sld_w * 0.05) * (v_max - v_min)
    elseif shift then
      if not _sld_drag_start[id] or _sld_drag_start[id].mode ~= "shift" then
  _sld_drag_start[id] = {mode="shift", my=my, val=new_val}
    end
      local ds = _sld_drag_start[id]
      new_val = ds.val + ((ds.my - my) / 150) * (v_max - v_min)
    else
      _sld_drag_start[id] = nil
      new_val = v_min + math.max(0, math.min(1, (mx - sx) / sld_w)) * (v_max - v_min)
    end
  elseif not active then
    _sld_drag_start[id] = nil
  end

  if is_int then new_val = math.floor(new_val + 0.5) end
  new_val = math.max(v_min, math.min(v_max, new_val))

  -- Dessin track + fill + grab
  local norm   = (v_max > v_min) and ((new_val - v_min) / (v_max - v_min)) or 0
  local gb     = 12
  local fill_x = sx + gb * 0.5 + norm * (sld_w - gb)
  local trk_h  = active and 10 or (hovered and 8 or 6)
  local trk_y  = sy + math.floor((sld_h - trk_h) * 0.5)

  local grab_col = disabled and hxa(T.C_DISABLED)
    or (active  and hxa(T.C_MORPH_GRAB_HV)
    or (hovered and hxa(T.C_MORPH_GRAB, 0.95)
    or               hxa(T.C_MORPH_GRAB, 0.80)))

  reaper.ImGui_DrawList_AddRectFilled(dl, sx, trk_y, sx+sld_w, trk_y+trk_h,
    disabled and hxa(T.C_BG_MAIN) or hxa(T.C_SLD_TRK), 4)
  if not disabled then
    local fa = active and 0.75 or (hovered and 0.68 or 0.55)
    reaper.ImGui_DrawList_AddRectFilled(dl, sx, trk_y, fill_x, trk_y+trk_h,
      hxa(T.C_MRF_SEL, fa), 4)
    local gw  = active and 16 or 14
    local gx1 = math.max(sx,       fill_x - gw * 0.5)
    local gx2 = math.min(sx+sld_w, fill_x + gw * 0.5)
    reaper.ImGui_DrawList_AddRectFilled(dl, gx1, sy+4, gx2, sy+sld_h-4, grab_col, 3)
  end

  local ba  = disabled and 0.18 or (active and 0.90 or (hovered and 0.65 or 0.40))
  reaper.ImGui_DrawList_AddRect(dl, sx, sy, sx+sld_w, sy+sld_h,
    disabled and hxa(T.C_BORDER, ba) or hxa(T.C_MORPH_GRAB, ba), 4, 0, 1.5)

  -- Min/max labels vertically centered
  local cy = sy + (sld_h - fh) * 0.5
  local sc = disabled and hxa(T.C_DISABLED, 0.50) or hxa(T.C_CFG_BASE, 0.90)
  reaper.ImGui_DrawList_AddText(dl, sx_full + math.floor((mar_l - min_w) * 0.5), cy, sc, min_str)
  reaper.ImGui_DrawList_AddText(dl, sx + sld_w + math.floor((mar_r - max_w) * 0.5), cy, sc, max_str)

  -- Value centered below track: double-click → inline InputText (no extra space added)
  -- opts.display_fn(raw_int) overrides the displayed value string
  local val_str = (opts.display_fn and opts.display_fn(math.floor(new_val + 0.5)))
               or (is_int and tostring(math.floor(new_val + 0.5))
                          or string.format(fmt or "%.2f", new_val))
  local vw    = reaper.ImGui_CalcTextSize(ctx, val_str)
  local val_x = sx + (sld_w - vw) * 0.5
  local val_y = sy + sld_h + 1
  local end_y = val_y + fh - 2

  if _sld_editing[id] then
    reaper.ImGui_SetCursorScreenPos(ctx, val_x - 5, val_y - 2)
    reaper.ImGui_SetNextItemWidth(ctx, vw + 10)
    if _sld_edit_buf[id] == nil then _sld_edit_buf[id] = val_str end
    _sld_edit_frame[id] = (_sld_edit_frame[id] or 0) + 1
    if _sld_edit_frame[id] == 1 then reaper.ImGui_SetKeyboardFocusHere(ctx) end

    local changed2, buf2 = reaper.ImGui_InputText(ctx, "##ed_"..id, _sld_edit_buf[id])
    if changed2 then _sld_edit_buf[id] = buf2 end

    local enter = reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Enter(), false)
              or  reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_KeypadEnter(), false)
    local clicked_outside = reaper.ImGui_IsMouseClicked(ctx, 0)
                        and not reaper.ImGui_IsItemHovered(ctx)
                        and _sld_edit_frame[id] > 2
    if reaper.ImGui_IsKeyPressed(ctx, reaper.ImGui_Key_Escape(), false) then
      _sld_editing[id] = nil ; _sld_edit_buf[id] = nil ; _sld_edit_frame[id] = nil
    elseif enter or clicked_outside then
      local p = tonumber(_sld_edit_buf[id])
      if p then
        new_val = math.max(v_min, math.min(v_max, p))
        if is_int then new_val = math.floor(new_val + 0.5) end
        _sld_committed[id] = new_val
      end
      _sld_editing[id] = nil ; _sld_edit_buf[id] = nil ; _sld_edit_frame[id] = nil
    end
    -- Reposition cursor to the same place as the non-edit branch (no Dummy)
    reaper.ImGui_SetCursorScreenPos(ctx, sx_full, end_y)
  else
    local vc = disabled and hxa(T.C_DISABLED, 0.55)
            or hxa(T.C_TXT_PRI, active and 1.0 or 0.82)
    reaper.ImGui_DrawList_AddRectFilled(dl,
      val_x - 3, val_y, val_x + vw + 3, val_y + fh + 1,
      hxa(T.C_BG_MAIN, 0.75), 2)
    reaper.ImGui_DrawList_AddText(dl, val_x, val_y + 1, vc, val_str)
    -- InvisibleButton bottom = val_y + (fh-2) = end_y → no phantom height tracked
    reaper.ImGui_SetCursorScreenPos(ctx, val_x - 10, val_y)
    reaper.ImGui_InvisibleButton(ctx, "##vclick_"..id, vw + 20, fh - 2)
    if not disabled and reaper.ImGui_IsItemHovered(ctx)
        and reaper.ImGui_IsMouseDoubleClicked(ctx, 0) then
      _sld_editing[id] = true ; _sld_edit_buf[id] = val_str ; _sld_edit_frame[id] = 0
    end
    reaper.ImGui_SetCursorScreenPos(ctx, sx_full, end_y)
  end

  if opts.return_active then return new_val, active end
  return new_val
end

-- ── Raccourcis ──────────────────────────────────────────────────

function M.drawInt(ctx, id, label, value, v_min, v_max, w, disabled, default_val, opts)
  local v = M.draw(ctx, id, label, value, v_min, v_max, nil, w, disabled, true, default_val, opts)
  if type(v) == "number" then return math.floor(v + 0.5) end
  return math.floor(v + 0.5)  -- return_active not supported for drawInt (use draw directly)
end

function M.drawFloat(ctx, id, label, value, v_min, v_max, fmt, w, disabled, default_val, opts)
  return M.draw(ctx, id, label, value, v_min, v_max, fmt, w, disabled, false, default_val, opts)
end

-- ── drawPair ────────────────────────────────────────────────────
-- Place two sliders side by side while managing the cursor manually.
-- fn_a(w, anchor_sx) / fn_b(w, anchor_sx) receive the width and X anchor.
function M.drawPair(ctx, avw, gap, fn_a, fn_b)
  gap = gap or 4
  local half    = math.floor((avw - gap) / 2)
  local sx, sy  = reaper.ImGui_GetCursorScreenPos(ctx)
  local col2_sx = sx + half + gap

  fn_a(half, nil)
  local _, sy_a = reaper.ImGui_GetCursorScreenPos(ctx)

  reaper.ImGui_SetCursorScreenPos(ctx, col2_sx, sy)
  fn_b(half, col2_sx)
  local _, sy_b = reaper.ImGui_GetCursorScreenPos(ctx)

  reaper.ImGui_SetCursorScreenPos(ctx, sx, math.max(sy_a, sy_b))
end

return M
