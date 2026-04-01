-- ============================================================
--   CommonFunction/EnvWriter.lua
--   Shared envelope-writing utilities used by RAND, LFO, MORPH.
--
--   Exports:
--     getEffectiveRange()                      → ts_s, ts_e, time_offset, has_item
--     resolveTarget()                          → env, ts_s, ts_e, time_offset
--     insertPoints(env, pts, ts_s, ts_len, target_idx)
--     finalizeAutomationItem(env, ts_s, ts_e)  → ai_idx
--     commitAutomationItem(env, pts, ts_s, ts_e) → ai_idx
-- ============================================================

local M = {}

local Logger     = require("Logger")
local EnvUtils   = require("EnvelopeUtils")
local EnvConvert = require("EnvConvert")

local toEnvValue = EnvConvert.toEnvValue

-- ── Effective range ──────────────────────────────────────────
-- Priority:
--   1. Item selected → time_offset = item_s
--      a. Time selection overlapping item → clamped ts
--      b. No valid ts → full item bounds
--   2. No item → time selection only (time_offset = 0)
--
-- Returns: ts_s, ts_e, time_offset, has_item
-- Returns nil when no item and no valid time selection.
function M.getEffectiveRange()
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item   = reaper.GetSelectedMediaItem(0, 0)
    local item_s = reaper.GetMediaItemInfo_Value(item, "D_POSITION")
    local item_e = item_s + reaper.GetMediaItemInfo_Value(item, "D_LENGTH")

    local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    local has_ts     = (ts_e - ts_s) >= 0.01

    if has_ts and ts_s < item_e and ts_e > item_s then
      local range_s = math.max(ts_s, item_s)
      local range_e = math.min(ts_e, item_e)
      if range_e - range_s >= 0.01 then
        return range_s, range_e, item_s, true
      end
    end

    if item_e - item_s >= 0.01 then
      return item_s, item_e, item_s, true
    end
    return nil
  end

  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if ts_e - ts_s < 0.01 then return nil end
  return ts_s, ts_e, 0, false
end

-- ── Target resolution ────────────────────────────────────────
-- Returns: env, ts_s, ts_e, time_offset
-- time_offset = item D_POSITION for take envelopes, 0 for track envelopes.
-- Points must be written at (t - time_offset) for take envelopes.
function M.resolveTarget()
  -- ── Case 1: selected media item ──────────────────────────────
  if reaper.CountSelectedMediaItems(0) > 0 then
    local item = reaper.GetSelectedMediaItem(0, 0)
    local take = reaper.GetActiveTake(item)
    if not take then
      Logger.error("⚠  Selected item has no active take") ; return nil
    end

    local n_take_env = reaper.CountTakeEnvelopes(take)
    if n_take_env == 0 then
      Logger.error("⚠  Selected item has no take FX envelope lane") ; return nil
    end
    local has_visible = false
    for e = 0, n_take_env - 1 do
      if EnvUtils.isVisible(reaper.GetTakeEnvelope(take, e)) then
        has_visible = true ; break
      end
    end
    if not has_visible then
      Logger.error("⚠  Selected item has no visible take FX envelope lane") ; return nil
    end

    local sel_env = reaper.GetSelectedEnvelope(0)
    if not sel_env then
      Logger.error("⚠  Click a take FX envelope lane on the item") ; return nil
    end
    local is_take_env = false
    for e = 0, n_take_env - 1 do
      if reaper.GetTakeEnvelope(take, e) == sel_env then
        is_take_env = true ; break
      end
    end
    if not is_take_env then
      Logger.error("⚠  Selected envelope is not a take FX envelope of this item") ; return nil
    end
    if not EnvUtils.isVisible(sel_env) then
      local _, en = reaper.GetEnvelopeName(sel_env)
      Logger.error("⚠  Take FX envelope '" .. en .. "' is not visible") ; return nil
    end

    local ts_s, ts_e, time_offset = M.getEffectiveRange()
    if not ts_s then
      Logger.error("⚠  Selected item is too short") ; return nil
    end
    return sel_env, ts_s, ts_e, time_offset
  end

  -- ── Case 2: time selection + selected track envelope ─────────
  local sel_env = reaper.GetSelectedEnvelope(0)
  if not sel_env then
    Logger.error("⚠  Select a media item + take FX lane, or set a time selection + envelope lane") ; return nil
  end
  if not EnvUtils.isVisible(sel_env) then
    local _, en = reaper.GetEnvelopeName(sel_env)
    Logger.error("⚠  Envelope '" .. en .. "' is not visible") ; return nil
  end
  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if ts_e - ts_s < 0.01 then
    Logger.error("⚠  Select an envelope lane and set a time selection") ; return nil
  end
  return sel_env, ts_s, ts_e, 0
end

-- ── Point insertion ──────────────────────────────────────────
-- Converts a [{tn, v, shape, tension}] list to native envelope
-- values and inserts them. target_idx defaults to -1 (base env).
function M.insertPoints(env, pts, ts_s, ts_len, target_idx)
  target_idx = target_idx or -1
  local conv         = EnvUtils.detectConverter(env)
  local lo, hi, mode = EnvUtils.resolveRange(env)
  for _, p in ipairs(pts) do
    reaper.InsertEnvelopePointEx(env, target_idx,
      ts_s + p.tn * ts_len,
      toEnvValue(p.v, conv, lo, hi, mode),
      p.shape, p.tension, false, true)
  end
end

-- ── Automation item finalize ─────────────────────────────────
-- Call AFTER all points have been written to the base envelope.
-- Creates the automation item (absorbs base points), then deletes
-- any residual base-envelope points in the range.
-- Returns ai_idx (≥0 on success, <0 on failure).
function M.finalizeAutomationItem(env, ts_s, ts_e)
  reaper.Envelope_SortPointsEx(env, -1)
  local ai_idx = reaper.InsertAutomationItem(env, -1, ts_s, ts_e - ts_s)
  reaper.DeleteEnvelopePointRangeEx(env, -1, ts_s - 0.0001, ts_e + 0.0001)
  reaper.Envelope_SortPointsEx(env, -1)
  return ai_idx
end

-- ── Automation item commit ───────────────────────────────────
-- Convenience: insertPoints then finalizeAutomationItem.
-- Use when you have a pre-built pts list (RAND, MORPH).
-- For generators that write points themselves (LFO), call
-- finalizeAutomationItem directly after the write loop.
function M.commitAutomationItem(env, pts, ts_s, ts_e)
  M.insertPoints(env, pts, ts_s, ts_e - ts_s)
  return M.finalizeAutomationItem(env, ts_s, ts_e)
end

return M
