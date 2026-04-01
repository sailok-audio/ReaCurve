-- ============================================================
--   TitleBar.lua
--   Custom title bar shared by all ReaCurve tools.
--   DrawList rendering + manual hit-test → snap / native docking OK.
--
--   Usage:
--     local TitleBar = require("TitleBar")
--     -- state = { collapsed=bool, dock_enabled=bool, hover_time=nil }
--     local want_close, want_dock, want_collapse = TitleBar.draw(ctx, dl, title, state)
-- ============================================================

local M = {}

local Theme = require("Theme")

M.TITLE_H    = 20
local HOVER_DELAY = 0.3

-- Palette (violet + rouge fermeture)
local VI_HOV    = "#5C3DC8"
local VI_BG     = "#4A32A8"
local CLOSE_HOV = "#A82222"

-- ── draw ─────────────────────────────────────────────────────
-- Draw the title bar and return button events.
-- state (table): { collapsed, dock_enabled, hover_time }  ← modified in place
-- Returns: want_close, want_dock, want_collapse
function M.draw(ctx, dl, title, state)
  local T       = Theme
  local TITLE_H = M.TITLE_H
  local win_w   = reaper.ImGui_GetWindowWidth(ctx)
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local sx, sy  = reaper.ImGui_GetCursorScreenPos(ctx)
  local fh      = reaper.ImGui_GetTextLineHeight(ctx)
  local focused = reaper.ImGui_IsWindowFocused(ctx)
  local mx, my  = reaper.ImGui_GetMousePos(ctx)

  -- ── Bar background ───────────────────────────────────────────
  local bar_bg = focused and T.hx(T.C_BG_PANEL2) or T.hx(T.C_BG_MAIN)
  reaper.ImGui_DrawList_AddRectFilled(dl,
    sx - 8, sy - 4, sx + win_w - 8, sy + TITLE_H + 1, bar_bg)
  reaper.ImGui_DrawList_AddLine(dl,
    sx - 8, sy + TITLE_H, sx + win_w - 8, sy + TITLE_H,
    T.hx(T.C_BORDER, focused and 0.35 or 0.18))

  -- ── Hit-test helper (does NOT consume ImGui events) ──────────
  local BTN_W = TITLE_H
  local btn_y = sy - 4
  local btn_h = TITLE_H + 4
  local function hit(bx, by, bw, bh)
    local hov = mx >= bx and mx < bx + bw and my >= by and my < by + bh
    return hov, hov and reaper.ImGui_IsMouseClicked(ctx, 0)
  end

  -- ── Centered title ──────────────────────────────────────────
  local txt_col = T.hx("#FFFFFF", focused and 0.70 or 0.33)
  reaper.ImGui_DrawList_AddText(dl,
    sx + 4, sy + math.floor((TITLE_H - fh) * 0.5),
    txt_col, title)

  -- ════════════════════════════════════════════════════════════
  --  Close button  (far right)  ✕
  -- ════════════════════════════════════════════════════════════
  local xbx = sx + avail_w - BTN_W
  local x_hov, x_clicked = hit(xbx, btn_y, BTN_W, btn_h)
  if x_hov then
    reaper.ImGui_DrawList_AddRectFilled(dl,
      xbx, btn_y, xbx + BTN_W, btn_y + btn_h,
      T.hx(CLOSE_HOV, 0.78), 2)
  end
  local xc   = xbx + BTN_W * 0.5
  local yc   = btn_y + btn_h * 0.5
  local xs   = 3.5
  local xcol = T.hx("#FFFFFF", x_hov and 1.0 or 0.48)
  reaper.ImGui_DrawList_AddLine(dl, xc - xs, yc - xs, xc + xs, yc + xs, xcol, 1.6)
  reaper.ImGui_DrawList_AddLine(dl, xc + xs, yc - xs, xc - xs, yc + xs, xcol, 1.6)

  -- ════════════════════════════════════════════════════════════
  --  Dock toggle button  (just left of ✕)
  -- ════════════════════════════════════════════════════════════
  local dbx = xbx - BTN_W - 3
  -- ════════════════════════════════════════════════════════════
  --  Collapse button  −/+  (just left of dock)
  -- ════════════════════════════════════════════════════════════
  local abx = dbx - BTN_W - 3
  local a_hov, a_clicked = hit(abx, btn_y, BTN_W, btn_h)
  if a_hov then
    reaper.ImGui_DrawList_AddRectFilled(dl,
      abx, btn_y, abx + BTN_W, btn_y + btn_h,
      T.hx(VI_HOV, 0.38), 2)
  end
  local ac  = T.hx("#FFFFFF", a_hov and 0.92 or 0.48)
  local acx = abx + BTN_W * 0.5
  local acy = btn_y + btn_h * 0.5
  local aw  = 4.5
  reaper.ImGui_DrawList_AddLine(dl, acx - aw, acy, acx + aw, acy, ac, 1.8)
  if state.collapsed then
    reaper.ImGui_DrawList_AddLine(dl, acx, acy - aw, acx, acy + aw, ac, 1.8)
  end
  local d_hov, d_clicked = hit(dbx, btn_y, BTN_W, btn_h)
  if d_hov then
    reaper.ImGui_DrawList_AddRectFilled(dl,
      dbx, btn_y, dbx + BTN_W, btn_y + btn_h,
      T.hx(VI_HOV, 0.38), 2)
  end

  local IS  = 10
  local off = 3
  local ix  = dbx + math.floor((BTN_W - IS) * 0.5)
  local iy  = btn_y + math.floor((btn_h - IS) * 0.5)

  local outline_a = state.dock_enabled
    and (d_hov and 0.95 or 0.72)
    or  (d_hov and 0.55 or 0.28)
  local fill_col = state.dock_enabled
    and T.hx(VI_BG,          d_hov and 1.0 or 0.82)
    or  T.hx(T.C_BG_PANEL2, 1.0)
  local icon_col = T.hx("#FFFFFF", outline_a)

  reaper.ImGui_DrawList_AddRect(dl,
    ix, iy, ix + IS - off, iy + IS - off, icon_col, 1, 0, 1.2)
  reaper.ImGui_DrawList_AddRectFilled(dl,
    ix + off, iy + off, ix + IS, iy + IS, fill_col, 1)
  reaper.ImGui_DrawList_AddRect(dl,
    ix + off, iy + off, ix + IS, iy + IS, icon_col, 1, 0, 1.0)
  if not state.dock_enabled then
    reaper.ImGui_DrawList_AddLine(dl,
      ix - 1, iy + IS + 1, ix + IS + 1, iy - 1,
      T.hx("#FF5050", d_hov and 0.92 or 0.65), 1.5)
  end

  -- ── Dock tooltip (hover delay) ───────────────────────────────
  if d_hov then
    if not state.hover_time then state.hover_time = reaper.time_precise() end
    if reaper.time_precise() - state.hover_time > HOVER_DELAY then
      reaper.ImGui_SetTooltip(ctx,
        state.dock_enabled and "Disable Docking" or "Enable Docking")
    end
  else
    state.hover_time = nil
  end

  -- ── Reserve height in the ImGui layout ───────────────────────
  reaper.ImGui_Dummy(ctx, avail_w, TITLE_H + 4)
  return x_clicked, d_clicked, a_clicked
end

return M
