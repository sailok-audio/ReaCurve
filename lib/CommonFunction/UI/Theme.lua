-- ============================================================
--   Theme.lua
--   Color palette and ImGui style helpers.
--   Edit this file to change the plugin appearance.
-- ============================================================

local M = {}

-- ── Color palette ────────────────────────────────────────────

M.C_BG_MAIN    = "#121417"
M.C_BG_PANEL   = "#1A1E23"
M.C_BG_PANEL2  = "#222831"
M.C_BORDER     = "#2E3640"

M.C_TXT_PRI    = "#F0F6FC"
M.C_TXT_SEC    = "#FFFFFF"
M.C_DISABLED   = "#5A6573"

M.C_AI1_BASE   = "#5B9EC9"
M.C_AI1_HOV    = "#7BBAD8"
M.C_AI1_SEL    = "#3A7BA8"
M.C_AI1_BG     = "#0A1820"

M.C_AI2_BASE   = "#9B6FE8"
M.C_AI2_HOV    = "#B48FF5"
M.C_AI2_SEL    = "#7040C8"
M.C_AI2_BG     = "#120E22"

M.C_MRF_BASE   = "#A3E635"
M.C_MRF_HOV    = "#BEF264"
M.C_MRF_SEL    = "#84CC16"
M.C_MRF_BG     = "#1A2408"

M.C_SLD_TRK    = "#39424C"

M.C_CFG_SEL    = "#3A4555"
M.C_CFG_BASE   = "#B8C4D0"
M.C_CFG_BG     = "#1C2230"

M.C_BTN_INS_BASE  = "#1E6FA8"
M.C_BTN_INS_HOV   = "#2A8FD8"
M.C_BTN_INS_PRESS = "#155585"
M.C_BTN_INS_BG    = "#050F18"

M.C_INFO       = "#FF6F00"

M.C_MORPH_GRAB    = "#A3E635"
M.C_MORPH_GRAB_HV = "#BEF264"

-- ── Color conversion helpers ─────────────────────────────────

-- Converts four [0,1] doubles to an ImU32 color.
function M.rgba(r, g, b, a)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a or 1.0)
end

-- Converts a hex color string ("#RRGGBB" or "#RRGGBBAA") to ImU32.
-- The optional alpha argument overrides the alpha channel.
function M.hx(h, alpha)
  local r = tonumber(h:sub(2, 3), 16) / 255
  local g = tonumber(h:sub(4, 5), 16) / 255
  local b = tonumber(h:sub(6, 7), 16) / 255
  local a = alpha or (#h >= 9 and tonumber(h:sub(8, 9), 16) / 255 or 1.0)
  return reaper.ImGui_ColorConvertDouble4ToU32(r, g, b, a)
end

-- ── ImGui style helpers ──────────────────────────────────────
-- These helpers push N style colors and return N so the caller can pop correctly.

-- Pushes button colors from hex strings.
-- Returns the number of colors pushed (4 or 5 if brd_hex is provided).
function M.pushButtonHex(ctx, bg_hex, hov_hex, txt_hex, brd_hex)
  local H = M.hx
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        H(bg_hex))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), H(hov_hex))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  H(hov_hex))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          H(txt_hex))
  if brd_hex then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), H(brd_hex))
    return 5
  end
  return 4
end

-- Pushes button colors from [0,1] RGB tuples.
-- Returns the number of colors pushed (4 or 5 if border rgb is provided).
function M.pushButtonRGB(ctx, bg_r,bg_g,bg_b, hov_r,hov_g,hov_b, txt_r,txt_g,txt_b, brd_r,brd_g,brd_b)
  local R = M.rgba
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        R(bg_r,  bg_g,  bg_b))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), R(hov_r, hov_g, hov_b))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  R(hov_r, hov_g, hov_b))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          R(txt_r, txt_g, txt_b))
  if brd_r then
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(), R(brd_r, brd_g, brd_b))
    return 5
  end
  return 4
end

return M
