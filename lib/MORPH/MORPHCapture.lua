-- ============================================================
--   MORPHCapture.lua
--   Capture workflow: snapshot AI data, poll for user selection,
--   build frozen sample arrays from envelope points.
-- ============================================================

local M = {}

local State       = require("MORPHState")
local Logger      = require("Logger")
local EnvUtils    = require("EnvelopeUtils")
local ReaperUtils = require("ReaperUtils")

local _saved_sel = nil

-- ── AI snapshot ───────────────────────────────────────────────
-- Reads all envelope data once and freezes it into Lua tables.
-- After this call, zero REAPER API calls are needed for this AI.
local function snapshotAI(ai)
  local live_env = ReaperUtils.getFreshEnv(ai)
  local N = 511   -- frozen_samples has N entries, positions (0/N)..(N-1)/N of ai.len

  if live_env then
    local _, _, mode = EnvUtils.getRange(live_env)
    local conv       = EnvUtils.detectConverter(live_env)
    ai.frozen_mode   = mode
    ai.converter     = conv

    -- Temporarily move overlapping AIs out of the way to avoid value summation
    local displaced = {}
    local n_ai = reaper.CountAutomationItems(live_env)
    for idx = 0, n_ai - 1 do
      if idx ~= ai.ai_idx then
        local o_pos = reaper.GetSetAutomationItemInfo(live_env, idx, "D_POSITION", 0, false)
        local o_len = reaper.GetSetAutomationItemInfo(live_env, idx, "D_LENGTH",   0, false)
        if o_pos < ai.pos + ai.len and o_pos + o_len > ai.pos then
          displaced[#displaced + 1] = { idx = idx, pos = o_pos }
          reaper.GetSetAutomationItemInfo(live_env, idx, "D_POSITION", -10000 - idx * 1000, true)
        end
      end
    end

    local raw_env = {}
    for i = 0, N - 1 do
      local t_abs = ai.pos + (i / N) * ai.len
      local ok, val = reaper.Envelope_Evaluate(live_env, t_abs, 0, 0)
      raw_env[i + 1] = (ok and ok >= 0) and val or 0
    end

    -- Restore displaced AIs
    for _, d in ipairs(displaced) do
      reaper.GetSetAutomationItemInfo(live_env, d.idx, "D_POSITION", d.pos, true)
    end

    if conv then
      ai.frozen_vmin    = 0
      ai.frozen_vmax    = 1
      ai.frozen_samples = {}
      for i = 1, N do
        if conv.type == "volume" then
          ai.frozen_samples[i] = conv:fromEnvelope(raw_env[i], mode)
        else
          ai.frozen_samples[i] = conv:fromNative(raw_env[i])
        end
      end
    else
      -- Generic: ScaleFromEnvelopeMode + normalize over observed range
      local vals        = {}
      local lo, hi      = math.huge, -math.huge
      for i = 1, N do
        local vf = reaper.ScaleFromEnvelopeMode(mode, raw_env[i])
        vals[i]  = vf
        if vf < lo then lo = vf end
        if vf > hi then hi = vf end
      end
      if hi - lo < 1e-6 then lo = lo - 0.05 ; hi = hi + 0.05 end
      ai.frozen_vmin    = lo
      ai.frozen_vmax    = hi
      local rng         = hi - lo
      ai.frozen_samples = {}
      for i = 1, N do
        ai.frozen_samples[i] = (vals[i] - lo) / rng
      end
    end
  else
    -- Fallback when no live envelope is accessible
    ai.frozen_mode   = nil
    ai.converter     = nil
    local raw_pts, _ = EnvUtils.getRawPoints(ai)
    local norm       = EnvUtils.normalisePts(raw_pts, ai.pos, ai.len)
    local lo, hi     = EnvUtils.computeVRange(norm)
    if hi - lo < 1e-6 then lo = lo - 0.05 ; hi = hi + 0.05 end
    ai.frozen_vmin    = lo
    ai.frozen_vmax    = hi
    local rng         = hi - lo
    local proxy       = { pts = norm }
    ai.frozen_samples = {}
    for i = 0, N - 1 do
      ai.frozen_samples[i + 1] = EnvUtils.evalSel(proxy, i / N)
    end
  end

  local raw_pts, msg   = EnvUtils.getRawPoints(ai)
  ai.frozen_norm       = EnvUtils.normalisePts(raw_pts, ai.pos, ai.len)
  ai.frozen_diag       = msg
end

-- ── Capture control ───────────────────────────────────────────

-- Starts a capture session for slot_n (1 or 2).
-- Saves the current selection and waits for the user to pick an AI or points.
function M.startCapture(slot_n)
  _saved_sel          = ReaperUtils.saveSelection()
  ReaperUtils.deselectAllAIs()
  ReaperUtils.deselectAllEnvPoints()
  State.capture_mode  = slot_n
  Logger.ok(string.format(
    "⏳  Source %d: select an automation item or envelope points", slot_n))
end

-- Cancels an active capture session and restores the previous selection.
function M.cancelCapture()
  State.capture_mode = 0
  Logger.ok("Capture cancelled")
  if _saved_sel then
    ReaperUtils.restoreSelection(_saved_sel)
    _saved_sel = nil
  end
end

-- ── Display cache refresh ────────────────────────────────────
-- Propagates frozen data from ai1/ai2 into State display fields.
-- Never calls REAPER — reads frozen_* fields set by snapshotAI.
function M.refreshCache()
  local k1 = State.ai1 and
    (State.ai1.track_idx..":"..State.ai1.env_idx..":"..State.ai1.ai_idx) or ""
  if k1 ~= State.prev_key1 then
    if State.ai1 then
      if not State.ai1.frozen_samples then snapshotAI(State.ai1) end
      State.norm1  = State.ai1.frozen_norm or {}
      State.diag1  = State.ai1.frozen_diag or ""
      State.vmin1  = State.ai1.frozen_vmin or 0
      State.vmax1  = State.ai1.frozen_vmax or 1
    else
      State.norm1 = {} ; State.diag1 = ""
      State.vmin1, State.vmax1 = 0, 1
    end
    State.prev_key1 = k1
  end

  local k2 = State.ai2 and
    (State.ai2.track_idx..":"..State.ai2.env_idx..":"..State.ai2.ai_idx) or ""
  if k2 ~= State.prev_key2 then
    if State.ai2 then
      if not State.ai2.frozen_samples then snapshotAI(State.ai2) end
      State.norm2  = State.ai2.frozen_norm or {}
      State.diag2  = State.ai2.frozen_diag or ""
      State.vmin2  = State.ai2.frozen_vmin or 0
      State.vmax2  = State.ai2.frozen_vmax or 1
    else
      State.norm2 = {} ; State.diag2 = ""
      State.vmin2, State.vmax2 = 0, 1
    end
    State.prev_key2 = k2
  end
end

-- ── Point selection capture ───────────────────────────────────
-- Snapshots selected envelope points into a frozen sel object for slot_n.
function M.captureSel(slot_n)
  local env = ReaperUtils.getActiveEnvelope()
  if not env then
    local track = reaper.GetSelectedTrack(0, 0)
    if not track then
      Logger.error("⚠  Select an envelope or a track") ; return
    end
    env = ReaperUtils.getActiveEnvelope(track)
    if not env then
      Logger.error("⚠  No visible envelope on this track") ; return
    end
  end

  local _, ename     = reaper.GetEnvelopeName(env)
  local lo, hi, mode = EnvUtils.resolveRange(env)
  local range        = hi - lo ; if math.abs(range) < 1e-9 then range = 1 end
  local conv         = EnvUtils.detectConverter(env)

  -- Converts a raw GetEnvelopePoint value to linear [0,1]
  local function toLinear(v_raw)
    if conv then
      if conv.type == "volume" then return conv:fromEnvelope(v_raw, mode)
      else                          return conv:fromNative(v_raw) end
    end
    local vf = reaper.ScaleFromEnvelopeMode(mode, v_raw)
    if mode == 1 then return vf end
    return (vf - lo) / range
  end

  local track_ref = reaper.GetSelectedTrack(0, 0)
  local tname, track_num = "", nil
  if track_ref then
    track_num = math.floor(reaper.GetMediaTrackInfo_Value(track_ref, "IP_TRACKNUMBER"))
    tname     = "TRK_" .. tostring(track_num)
  end

  -- Read selected points (single REAPER pass)
  local raw_pts = {}
  local n = reaper.CountEnvelopePointsEx(env, -1)
  for i = 0, n - 1 do
    local ok, t, v, sh, tn_val, sel_flag = reaper.GetEnvelopePointEx(env, -1, i)
    if ok and sel_flag then
      raw_pts[#raw_pts+1] = { t=t, v=v, shape=sh or 0, tension=tn_val or 0 }
    end
  end

  if #raw_pts < 2 then
    Logger.error("⚠  Select at least 2 envelope points") ; return
  end

  table.sort(raw_pts, function(a, b) return a.t < b.t end)
  local t0  = raw_pts[1].t
  local t1  = raw_pts[#raw_pts].t
  local len = t1 - t0 ; if len < 1e-6 then len = 1 end

  local pts = {}
  for _, p in ipairs(raw_pts) do
    pts[#pts+1] = {
      tn      = (p.t - t0) / len,
      v       = toLinear(p.v),
      shape   = p.shape   or 0,
      tension = p.tension or 0,
    }
  end

  local src = string.format("%d pts sel.", #pts)
  local lbl = ReaperUtils.formatSlotLabel(tname, ename, src)

  -- Temporarily move overlapping AIs to get clean Envelope_Evaluate readings
  local displaced = {}
  local n_ai = reaper.CountAutomationItems(env)
  for idx = 0, n_ai - 1 do
    local o_pos = reaper.GetSetAutomationItemInfo(env, idx, "D_POSITION", 0, false)
    local o_len = reaper.GetSetAutomationItemInfo(env, idx, "D_LENGTH",   0, false)
    if o_pos < t0 + len and o_pos + o_len > t0 then
      displaced[#displaced + 1] = { idx = idx, pos = o_pos }
      reaper.GetSetAutomationItemInfo(env, idx, "D_POSITION", -10000 - idx * 1000, true)
    end
  end

  local N = 127
  local raw_eval = {}
  for i = 0, N - 1 do
    local t_abs   = t0 + (i / (N - 1)) * len
    local ok, val = reaper.Envelope_Evaluate(env, t_abs, 0, 0)
    raw_eval[i + 1] = (ok and ok >= 0) and val or 0
  end

  for _, d in ipairs(displaced) do
    reaper.GetSetAutomationItemInfo(env, d.idx, "D_POSITION", d.pos, true)
  end

  -- Build frozen_samples (same logic as snapshotAI)
  local frozen_samples, fs_lo, fs_hi
  if conv then
    fs_lo = 0 ; fs_hi = 1
    frozen_samples = {}
    for i = 1, N do
      if conv.type == "volume" then
        frozen_samples[i] = conv:fromEnvelope(raw_eval[i], mode)
      else
        frozen_samples[i] = conv:fromNative(raw_eval[i])
      end
    end
  else
    local vals = {}
    fs_lo, fs_hi = math.huge, -math.huge
    for i = 1, N do
      local vf = reaper.ScaleFromEnvelopeMode(mode, raw_eval[i])
      vals[i]  = vf
      if vf < fs_lo then fs_lo = vf end
      if vf > fs_hi then fs_hi = vf end
    end
    if fs_hi - fs_lo < 1e-6 then fs_lo = fs_lo - 0.05 ; fs_hi = fs_hi + 0.05 end
    local fs_rng   = fs_hi - fs_lo
    frozen_samples = {}
    for i = 1, N do
      frozen_samples[i] = (vals[i] - fs_lo) / fs_rng
    end
  end

  local result = {
    pts            = pts,
    label          = lbl,
    mode           = mode,
    vmin           = fs_lo,
    vmax           = fs_hi,
    len            = len,
    tname          = tname,
    ename          = ename,
    track_num      = track_num,
    t0_abs         = t0,
    len_eval       = len,
    lo_range       = lo,
    hi_range       = hi,
    frozen_samples = frozen_samples,
    converter      = conv,
  }

  if slot_n == 1 then
    State.sel1       = result
    State.slot1_type = "sel"
    Logger.ok("✔  ENV 1 captured: " .. ename)
  else
    State.sel2       = result
    State.slot2_type = "sel"
    Logger.ok("✔  ENV 2 captured: " .. ename)
  end
  State.invalidatePreview()

  -- Deselect points for visual feedback
  local n_pts = reaper.CountEnvelopePointsEx(env, -1)
  for i = 0, n_pts - 1 do
    local ok2, t2, v2, sh2, tn2, sel_flag = reaper.GetEnvelopePointEx(env, -1, i)
    if ok2 and sel_flag then
      reaper.SetEnvelopePointEx(env, -1, i, t2, v2, sh2, tn2, false, true)
    end
  end
  reaper.Envelope_SortPointsEx(env, -1)
  reaper.UpdateArrange()
end

-- ── Per-frame poll ────────────────────────────────────────────
-- Called every frame. Detects a completed capture (AI click or point selection)
-- and finalizes the slot.
function M.pollCapture()
  if State.capture_mode == 0 then return end

  -- Priority 1: selected automation item
  local ai_sel = ReaperUtils.getSelectedAI()
  if ai_sel then
    snapshotAI(ai_sel)
    if State.capture_mode == 1 then
      State.ai1 = ai_sel ; State.prev_key1 = nil ; State.slot1_type = "ai"
      Logger.ok("✔  AI 1 captured: " .. ai_sel.label)
    else
      State.ai2 = ai_sel ; State.prev_key2 = nil ; State.slot2_type = "ai"
      Logger.ok("✔  AI 2 captured: " .. ai_sel.label)
    end
    State.capture_mode = 0
    State.invalidatePreview()
    if _saved_sel then ReaperUtils.restoreSelection(_saved_sel) ; _saved_sel = nil end
    return
  end

  -- Priority 2: selected envelope points
  local env = ReaperUtils.getActiveEnvelope()
  if env then
    local n = reaper.CountEnvelopePointsEx(env, -1)
    for i = 0, n - 1 do
      local ok, _, _, _, _, sel_flag = reaper.GetEnvelopePointEx(env, -1, i)
      if ok and sel_flag then
        M.captureSel(State.capture_mode)
        State.capture_mode = 0
        if _saved_sel then ReaperUtils.restoreSelection(_saved_sel) ; _saved_sel = nil end
        return
      end
    end
  end
end

return M