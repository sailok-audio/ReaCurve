-- ============================================================
--   CommonFunction/Toggle.lua
--   Two-state toggle button, violet pill style.
--   Shared by: LFOPanel, RANDPanel, SCULPTPanel.
--
--   Usage:
--     local Toggle = require("Toggle")
--     local changed = Toggle.draw(ctx, id, w, h, label_a, label_b, is_a_active)
--     local changed = Toggle.draw(ctx, id, w, h, label_a, label_b, is_a, { disabled=true })
-- ============================================================

local M = {}

local Theme = require("Theme")
local T     = Theme

local VI_ON_BG  = "#4A32A8"
local VI_ON_HOV = "#5C3DC8"
local VI_ON_BRD = "#7B5CE0"

-- Draw a two-state pill toggle.
-- opts (optional): { disabled = bool }
-- Returns: changed (bool) — true if the user toggled the state.
-- If opts.disabled is true, the toggle is inert and always returns false.
function M.draw(ctx, id, w, h, label_a, label_b, is_a_active, opts)
  opts = opts or {}
  local disabled = opts.disabled or false

  local dl     = reaper.ImGui_GetWindowDrawList(ctx)
  local sx, sy = reaper.ImGui_GetCursorScreenPos(ctx)
  local hw     = math.floor((w - 2) / 2)
  local rad    = math.floor(h * 0.5)

  -- Fond conteneur pill
  reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+w, sy+h, T.hx(T.C_BG_MAIN, 0.70), rad)
  reaper.ImGui_DrawList_AddRect(dl,      sx, sy, sx+w, sy+h, T.hx(VI_ON_BRD, 0.45),    rad, 0, 1.0)
  -- Center separator
  reaper.ImGui_DrawList_AddLine(dl, sx+hw+1, sy+2, sx+hw+1, sy+h-2, T.hx(VI_ON_BRD, 0.30), 1.0)

  local function pushOn()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(VI_ON_BG))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(VI_ON_BG))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(VI_ON_HOV))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx("#E8DDFF"))
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(),   rad)
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 1.5)
  end
  local function pushOff()
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.rgba(0, 0, 0, 0))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.rgba(0, 0, 0, 0))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(VI_ON_BG, 0.35))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_DISABLED))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.rgba(0, 0, 0, 0))
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameRounding(),   rad)
    reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 0.0)
  end

  local changed = false
  if disabled then reaper.ImGui_BeginDisabled(ctx) end

  if is_a_active then pushOn() else pushOff() end
  if reaper.ImGui_Button(ctx, label_a.."##"..id.."a", hw, h) and not is_a_active then
    changed = true
  end
  reaper.ImGui_PopStyleColor(ctx, 5) ; reaper.ImGui_PopStyleVar(ctx, 2)

  reaper.ImGui_SameLine(ctx, 0, 2)

  if not is_a_active then pushOn() else pushOff() end
  if reaper.ImGui_Button(ctx, label_b.."##"..id.."b", hw, h) and is_a_active then
    changed = true
  end
  reaper.ImGui_PopStyleColor(ctx, 5) ; reaper.ImGui_PopStyleVar(ctx, 2)

  if disabled then
    reaper.ImGui_EndDisabled(ctx)
    -- Overlay semi-transparent pour visuellement griser (BeginDisabled n'affecte pas PushStyleColor)
    reaper.ImGui_DrawList_AddRectFilled(dl, sx, sy, sx+w, sy+h, T.hx(T.C_BG_MAIN, 0.58), rad)
  end

  return changed and not disabled
end

return M
