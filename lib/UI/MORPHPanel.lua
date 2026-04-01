-- ============================================================
--   MORPHPanel.lua
--   Composed UI panels. Each panel reads MORPHState, calls Widgets
--   for all rendering, and triggers service calls on user actions.
--   No inline style customization — that lives in Widgets.lua.
-- ============================================================

local M = {}

local Theme       = require("Theme")
local Widgets     = require("Widgets")
local State       = require("MORPHState")
local Logger      = require("Logger")
local Config      = require("MORPHConfig")
local Capture     = require("MORPHCapture")
local Generate    = require("MORPHWrite")
local ReaperUtils = require("ReaperUtils")
local MorphEngine = require("MORPHEngine")
local EnvUtils    = require("EnvelopeUtils")

local T = Theme

-- ── Blink / pulse helpers ─────────────────────────────────────

-- Sinusoidal pulse [0,1] at freq_hz.
local function pulse(freq_hz)
  return (math.sin(reaper.time_precise() * math.pi * 2 * freq_hz) + 1) * 0.5
end

-- Alpha that blinks for BLINK_DURATION seconds then settles at alpha_hi.
local BLINK_DURATION = 4.0
local function warnAlpha(start_t, freq_hz, alpha_hi, alpha_lo)
  if not start_t then return alpha_hi end
  local elapsed = reaper.time_precise() - start_t
  if elapsed >= BLINK_DURATION then return alpha_hi end
  local fade = 1.0 - (elapsed / BLINK_DURATION)
  local p    = (math.sin(elapsed * math.pi * 2 * freq_hz) + 1) * 0.5
  return alpha_hi - (alpha_hi - alpha_lo) * (1 - p) * fade
end

-- Timestamps and previous-state flags for blink animation
local _warn_src_t,    _warn_trk_t    = nil, nil
local _prev_src_warn, _prev_trk_warn = false, false
local _status_err_t   = nil
local _prev_status_ok = true

-- ── Source slot panel ─────────────────────────────────────────

-- Draws the full source slot UI (capture/recapture button + mini-graph label).
-- slot_n: 1 or 2.
function M.drawSourceSlot(ctx, dl, slot_n)
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local bh      = 30
  local is1     = (slot_n == 1)
  local stype   = is1 and State.slot1_type or State.slot2_type
  local waiting = (State.capture_mode == slot_n)

  -- Determine widget state and badge text
  local widget_state = "empty"
  local badge        = nil
  if waiting then
    widget_state = "waiting"
  elseif stype ~= nil then
    widget_state = "captured"
    badge        = (stype == "ai") and " AI " or "ENV"
  end

  -- Draw the button and handle the returned action
  local action = Widgets.drawSourceSlotButton(ctx, dl, slot_n, widget_state, badge, avail_w, bh)

  if action == "capture" or action == "recapture" then
    Capture.startCapture(slot_n)
  elseif action == "cancel" then
    Capture.cancelCapture()
  elseif action == "clear" then
    State.clearSlot(slot_n)
    Logger.ok("Source " .. slot_n .. " cleared")
  end
end

-- ── Source slot mini-graph ───────────────────────────────────

-- Draws the mini-graph for slot_n using frozen sample data.
function M.drawSlotMiniGraph(dl, px, py, pw, ph, slot_n)
  local is1  = (slot_n == 1)
  local stype = is1 and State.slot1_type or State.slot2_type
  local vals  = {}

  if stype == "sel" then
    local src = is1 and State.sel1 or State.sel2
    if src then
      for i = 0, 79 do vals[#vals+1] = EnvUtils.evalSel(src, i/79) end
    end
  elseif stype == "ai" then
    local obj = is1 and State.ai1 or State.ai2
    if obj and obj.frozen_samples then
      vals = EnvUtils.sampleFrozenNorm(obj.frozen_samples, 80)
    end
  end

  Widgets.drawMiniGraph(dl, px, py, pw, ph, vals, slot_n, #vals == 0)
end

-- ── Main morph graph ─────────────────────────────────────────

-- Draws the full morph curve graph with background, curves, dots, and morph bar.
function M.drawMainGraph(ctx, dl, px, py, pw, ph)
  Widgets.drawGraphBG(dl, px, py, pw, ph, T.hx(T.C_BG_PANEL))
  Widgets.drawYLabels(ctx, dl, px, py, pw, ph)

  local has_data = State.slotReady(1) and State.slotReady(2) and #State.prev_samples >= 2

  if not has_data then
    local msg  = "Capture Source 1 and Source 2"
    local mw   = reaper.ImGui_CalcTextSize(ctx, msg)
    local fh   = reaper.ImGui_GetTextLineHeight(ctx)
    local mx   = px + (pw - mw) * 0.5
    local my   = py + (ph - fh) * 0.5
    reaper.ImGui_DrawList_AddRectFilled(dl, mx-6, my-2, mx+mw+6, my+fh+2, T.hx(T.C_BG_MAIN, 0.82), 3)
    reaper.ImGui_DrawList_AddText(dl, mx, my, T.hx(T.C_DISABLED), msg)
  else
    -- Interpolate curve color between slot 1 (blue) and slot 2 (purple)
    local r1,g1,b1 = 0.10, 0.65, 1.00
    local r2,g2,b2 = 0.65, 0.35, 1.00
    local mr = r1 + State.morph*(r2-r1)
    local mg = g1 + State.morph*(g2-g1)
    local mb = b1 + State.morph*(b2-b1)
    local dragging = State.slider_dragging or State.bar_dragging
    local thick    = dragging and 2.5 or 2.2
    local alpha    = dragging and 1.0 or 0.88
    if dragging then mr=math.min(1,mr+0.3) ; mg=math.min(1,mg+0.3) ; mb=math.min(1,mb+0.3) end

    local draw_pts = MorphEngine.smoothCurvePoints(State.prev_samples, 4)

    if dragging then
      -- Glow passes use raw (unsmoothed) points to avoid additive noise on dense lines
      local raw = State.prev_samples
      Widgets.drawCurvePts(dl, px, py, pw, ph, raw, T.rgba(mr,mg,mb,0.05), 10.0)
      Widgets.drawCurvePts(dl, px, py, pw, ph, raw, T.rgba(mr,mg,mb,0.07),  6.0)
    end
    Widgets.drawCurvePts(dl, px, py, pw, ph, draw_pts, T.rgba(mr,mg,mb,alpha), thick)

    if not dragging and #State.prev_fitted_stable >= 2 then
      Widgets.drawFittedDots(ctx, dl, px, py, pw, ph,
        State.prev_fitted_stable, T.hx("#E8E8E8", 0.88))
    end
  end

  -- Draggable morph bar
  local new_morph, still_bar = Widgets.drawMorphBar(ctx, dl, px, py, pw, ph,
    State.morph, State.bar_dragging, State.slider_dragging)

  if new_morph ~= State.morph then
    State.morph = new_morph
    State.invalidatePreview()
  end
  if still_bar ~= State.bar_dragging then
    State.bar_dragging = still_bar
    if not still_bar then
      State.invalidatePreview()
      MorphEngine.refreshPreview()
    end
  end
  if State.bar_dragging then
    MorphEngine.refreshPreviewFast()
  end

  reaper.ImGui_DrawList_AddRect(dl, px, py, px+pw, py+ph, T.hx("#FFFFFF", 0.12))
end

-- ── Options panel ────────────────────────────────────────────

-- Draws the Precision combo box.
function M.drawMorphPanel(ctx)
  local avail_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))

  -- Unified combo style (violet) via Widgets
  Widgets.pushComboStyle(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, avail_w)
  if reaper.ImGui_BeginCombo(ctx, "##preset_combo",
      "Precision: " .. Config.PRESETS[Config.active_preset].name) then
    for i, p in ipairs(Config.PRESETS) do
      local sel = (i == Config.active_preset)
      if sel then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
      if reaper.ImGui_Selectable(ctx, p.name.."##pc"..i, sel) then
        Config.applyPreset(i) ; State.invalidatePreview()
      end
      if sel then reaper.ImGui_PopStyleColor(ctx) ; reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  Widgets.popComboStyle(ctx)
end

-- ── Generate / Insert panel ───────────────────────────────────

-- Draws the two INSERT buttons. ctx_info comes from ReaperUtils.getContextInfo().
function M.drawGeneratePanel(ctx, dl, ctx_info)
  local slots_ok = State.slotReady(1) and State.slotReady(2)
  Widgets.drawInsertPanel(ctx, dl, ctx_info,
    function()
      reaper.Undo_BeginBlock()
      Generate.generateTimeSelection()
      reaper.Undo_EndBlock("Morph – envelope points", -1)
    end,
    function()
      reaper.Undo_BeginBlock()
      Generate.generateAutomationItem()
      reaper.Undo_EndBlock("Morph – automation item", -1)
    end,
    slots_ok)
end

-- ── Context panel ─────────────────────────────────────────────

-- Draws the context info row showing the current target or warnings.
function M.drawContextPanel(ctx, dl, ctx_info)
  local sw2      = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local sx2, sy2 = reaper.ImGui_GetCursorScreenPos(ctx)
  local fh       = reaper.ImGui_GetTextLineHeight(ctx)
  local pill_h   = fh + 8
  local now      = reaper.time_precise()

  reaper.ImGui_DrawList_AddRectFilled(dl, sx2, sy2, sx2+sw2, sy2+pill_h, T.hx(T.C_INFO, 0.07), 4)

  local src_warn    = not State.slotReady(1) or not State.slotReady(2)
  local trk_warn_msg = nil
  if State.slotReady(1) and State.slotReady(2) and not ctx_info.has_target then
    local ci = ctx_info
    if ci.track_num == nil and (not ci.item_count or ci.item_count == 0) then
      trk_warn_msg = "⚠  No track or media item selected"
    elseif ci.item_count and ci.item_count > 0 and not ci.all_items_ok then
      trk_warn_msg = "⚠  No take envelope visible on selected item"
    else
      trk_warn_msg = "⚠  No envelope track selected"
    end
  end
  local trk_warn = (trk_warn_msg ~= nil)

  -- Update blink timestamps on state change
  if src_warn ~= _prev_src_warn then
    _warn_src_t    = src_warn and now or nil
    _prev_src_warn = src_warn
  end
  if trk_warn ~= _prev_trk_warn then
    _warn_trk_t    = trk_warn and now or nil
    _prev_trk_warn = trk_warn
  end

  local line, text_alpha
  if src_warn then
    if not State.slotReady(1) and not State.slotReady(2) then
      line = "⚠  Capture Source 1 and Source 2 to begin"
    elseif not State.slotReady(1) then
      line = "⚠  Source 1 not captured"
    else
      line = "⚠  Source 2 not captured"
    end
    text_alpha = warnAlpha(_warn_src_t, 1.2, 0.82, 0.28)

  elseif trk_warn then
    line       = trk_warn_msg
    text_alpha = warnAlpha(_warn_trk_t, 1.2, 0.88, 0.28)

  else
    -- Normal mode: icon anchored left, truncated target label
    local ci    = ctx_info
    local ic_w  = 14
    local pad_l = 10
    local gap   = 6
    local pad_r = 10
    local ic_x  = sx2 + pad_l
    local txt_x = ic_x + ic_w + gap
    local cy_ic = sy2 + pill_h * 0.5
    local ic_col = T.hx(T.C_INFO, 0.80)

    -- Target icon (time-selection arrows or playhead triangle)
    if ci.use_ts then
      local lx, rx = ic_x+1, ic_x+ic_w-1
      reaper.ImGui_DrawList_AddLine(dl, lx, cy_ic-5, lx, cy_ic+5, ic_col, 1.5)
      reaper.ImGui_DrawList_AddLine(dl, rx, cy_ic-5, rx, cy_ic+5, ic_col, 1.5)
      reaper.ImGui_DrawList_AddLine(dl, lx+2, cy_ic, rx-2, cy_ic, ic_col, 1.0)
    else
      local ts = 5
      reaper.ImGui_DrawList_AddTriangleFilled(dl,
        ic_x, cy_ic-ts, ic_x, cy_ic+ts, ic_x+ts*1.6, cy_ic, ic_col)
    end

    -- Target label
    local tgt
    if ci.item_count and ci.item_count > 1 then
      tgt = string.format("%d items · %s", ci.item_count, ci.env_name or "?")
    elseif ci.is_item_env and ci.track_num and ci.item_idx and ci.env_name then
      tgt = string.format("TRK_%d · Item %d › %s", ci.track_num, ci.item_idx, ci.env_name)
    elseif ci.env_name and ci.track_num then
      tgt = string.format("TRK_%d › %s", ci.track_num, ci.env_name)
    elseif ci.track_num then
      tgt = string.format("TRK_%d › select an envelope", ci.track_num)
    else
      tgt = ci.env_name or "?"
    end

    local pos_str  = ci.use_ts and string.format("%.2fs", ci.ts_s)
                                or string.format("%.2fs", ci.cursor)
    local prefix   = pos_str .. "   →   "
    local prefix_w = reaper.ImGui_CalcTextSize(ctx, prefix)
    local max_txt_w = sw2 - pad_l - ic_w - gap - pad_r
    local avail_tgt = max_txt_w - prefix_w
    local ellipsis  = "…"
    local ew        = reaper.ImGui_CalcTextSize(ctx, ellipsis)
    if reaper.ImGui_CalcTextSize(ctx, tgt) > avail_tgt then
      while #tgt > 0 and reaper.ImGui_CalcTextSize(ctx, tgt) + ew > avail_tgt do
        tgt = tgt:gsub("[\128-\191]*.$", "")
      end
      tgt = tgt .. ellipsis
    end

    reaper.ImGui_DrawList_AddText(dl, txt_x, sy2 + (pill_h - fh) * 0.5,
      ic_col, prefix .. tgt)
    line = ""
  end

  if line and line ~= "" then
    local lw = reaper.ImGui_CalcTextSize(ctx, line)
    reaper.ImGui_DrawList_AddText(dl,
      sx2+(sw2-lw)*0.5, sy2+(pill_h-fh)*0.5, T.hx(T.C_INFO, text_alpha), line)
  end
  reaper.ImGui_Dummy(ctx, sw2, pill_h)
end

-- ── Status bar ───────────────────────────────────────────────

-- Draws the status message bar. Delegates to Widgets.drawStatusBar.
function M.drawStatusBar(ctx, dl)
  Widgets.drawStatusBar(ctx, dl)
end

return M