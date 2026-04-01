-- ============================================================
--   MORPHWrite.lua
--   Writes the morphed result into REAPER:
--   envelope points in time selection, or a new automation item.
-- ============================================================

local M = {}

local State       = require("MORPHState")
local Logger      = require("Logger")
local EnvUtils    = require("EnvelopeUtils")
local MorphEngine = require("MORPHEngine")
local Capture     = require("MORPHCapture")
local ReaperUtils = require("ReaperUtils")
local EnvWriter   = require("EnvWriter")

-- ── Time range resolution ────────────────────────────────────

-- Returns (ts_s, ts_e, is_auto).
-- is_auto = true when no valid time selection exists (uses cursor + source length).
local function resolveTimeRange()
  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if ts_e - ts_s >= 0.01 then return ts_s, ts_e, false end
  local cursor = reaper.GetCursorPosition()
  local length = math.max(State.getSlotLen(1), State.getSlotLen(2), 0.1)
  return cursor, cursor + length, true
end

-- ── Neighbor value lookup ────────────────────────────────────

-- Reads the envelope value just before ts_s and at ts_e for edge continuity.
-- time_offset is the item's D_POSITION (0 for track envelopes).
-- Returns (v_prev, v_next) normalized to [0,1], either may be nil.
local function getNeighborValues(env, ts_s, ts_e, time_offset)
  if not env then return nil, nil end
  time_offset   = time_offset or 0
  local rel_s   = ts_s - time_offset
  local rel_e   = ts_e - time_offset

  local conv          = EnvUtils.detectConverter(env)
  local lo, hi, mode  = EnvUtils.resolveRange(env)
  local range         = hi - lo ; if math.abs(range) < 1e-9 then range = 1 end

  local function normalize(v_raw)
    if conv then
      if conv.type == "volume" then return conv:fromEnvelope(v_raw, mode)
      else                          return conv:fromNative(v_raw) end
    end
    local vf = reaper.ScaleFromEnvelopeMode(mode, v_raw)
    if mode == 1 then return vf end
    return (vf - lo) / range
  end

  local v_prev, t_prev_best = nil, -math.huge
  local n = reaper.CountEnvelopePointsEx(env, -1)
  if n and n > 0 then
    for i = 0, n - 1 do
      local ok, t, v = reaper.GetEnvelopePointEx(env, -1, i)
      if ok and t < rel_s - 0.0001 and t > t_prev_best then
        t_prev_best = t ; v_prev = normalize(v)
      end
    end
  end

  local v_next
  local ok2, val = reaper.Envelope_Evaluate(env, rel_e, 0, 0)
  if ok2 and ok2 >= 0 then v_next = normalize(val) end

  return v_prev, v_next
end

-- ── Take envelope lookup ─────────────────────────────────────

-- Returns the first visible take envelope on an item's active take.
-- Returns (env, ename, take) or (nil, nil, take_or_nil).
local function findVisibleTakeEnv(item)
  local take = reaper.GetActiveTake(item)
  if not take then return nil, nil, nil end
  for ei = 0, reaper.CountTakeEnvelopes(take) - 1 do
    local env = reaper.GetTakeEnvelope(take, ei)
    if EnvUtils.isVisible(env) then
      local _, ename = reaper.GetEnvelopeName(env)
      return env, ename, take
    end
  end
  return nil, nil, take
end

-- ── Target builder ───────────────────────────────────────────

-- Builds a complete target record for a single item/envelope.
-- Computes time_offset, clamps ts to item bounds, reads neighbor values,
-- and calls MorphEngine to produce the point list.
-- Returns (target_table, nil) or (nil, error_string).
local function buildItemTarget(env, ename, parent_item, parent_take, ts_s, ts_e, is_auto)
  local time_offset = reaper.GetMediaItemInfo_Value(parent_item, "D_POSITION")
  local item_len    = reaper.GetMediaItemInfo_Value(parent_item, "D_LENGTH")
  local item_end    = time_offset + item_len

  local my_ts_s, my_ts_e = ts_s, ts_e
  if not is_auto then
    if my_ts_s >= item_end or my_ts_e <= time_offset then
      return nil, "time selection outside item range"
    end
    my_ts_s = math.max(my_ts_s, time_offset)
    my_ts_e = math.min(my_ts_e, item_end)
  else
    my_ts_s = time_offset
    my_ts_e = item_end
  end

  local v_prev, v_next = getNeighborValues(env, my_ts_s, my_ts_e, time_offset)
  local pts            = MorphEngine.buildMorphSamples(v_prev, v_next)

  local tr_num = 0
  local ptrack = reaper.GetMediaItemInfo_Value(parent_item, "P_TRACK")
  if ptrack and ptrack ~= 0 then
    tr_num = math.floor(reaper.GetMediaTrackInfo_Value(ptrack, "IP_TRACKNUMBER"))
  end

  return {
    env         = env,
    ename       = ename,
    parent_item = parent_item,
    parent_take = parent_take,
    time_offset = time_offset,
    ts_s        = my_ts_s,
    ts_e        = my_ts_e,
    rel_s       = my_ts_s - time_offset,
    rel_e       = my_ts_e - time_offset,
    ts_len      = my_ts_e - my_ts_s,
    pts         = pts,
    tr_num      = tr_num,
  }, nil
end

-- ── Status tag builder ───────────────────────────────────────

local function makeTag(ctx_data)
  if ctx_data.n_items and ctx_data.n_items > 1 then
    return ctx_data.n_items .. " items"
  end
  if ctx_data.is_item_env then
    local idx = ctx_data.parent_item and ReaperUtils.getItemIndexOnTrack(ctx_data.parent_item)
    if idx then return string.format("TRK_%d·I%d", ctx_data.tr_num, idx) end
    return string.format("TRK_%d·Item", ctx_data.tr_num)
  end
  return string.format("TRK_%d", ctx_data.tr_num)
end

-- ── Write preparation ────────────────────────────────────────
-- Validates slots and resolves the target envelope(s).
-- Returns a ctx table or nil (sets Logger message on failure).
local function prepareWrite()
  if not State.slotReady(1) or not State.slotReady(2) then
    Logger.error("⚠  Capture Source 1 and Source 2") ; return nil
  end

  if State.slot1_type == "ai" then State.prev_key1 = nil end
  if State.slot2_type == "ai" then State.prev_key2 = nil end
  Capture.refreshCache()

  local ts_s, ts_e, is_auto = resolveTimeRange()

  -- Path A: explicitly selected envelope
  local sel_env = reaper.GetSelectedEnvelope(0)
  if sel_env then
    if not EnvUtils.isVisible(sel_env) then
      local _, en = reaper.GetEnvelopeName(sel_env)
      Logger.error("⚠  Envelope '" .. en .. "' is not visible or inactive — show it first")
      return nil
    end
    local _, ename = reaper.GetEnvelopeName(sel_env)
    local p_take   = reaper.GetEnvelopeInfo_Value(sel_env, "P_TAKE")
    local p_item_v = reaper.GetEnvelopeInfo_Value(sel_env, "P_ITEM")
    local p_track  = reaper.GetEnvelopeInfo_Value(sel_env, "P_TRACK")

    if p_take and p_take ~= 0 then
      local parent_item = reaper.GetMediaItemTake_Item(p_take)
      local tgt, err    = buildItemTarget(sel_env, ename, parent_item, p_take, ts_s, ts_e, is_auto)
      if not tgt then Logger.error("⚠  " .. err) ; return nil end
      return { targets={tgt}, is_item_env=true, n_items=1, ename=ename, tr_num=tgt.tr_num }

    elseif p_item_v and p_item_v ~= 0 then
      local tgt, err = buildItemTarget(sel_env, ename, p_item_v, nil, ts_s, ts_e, is_auto)
      if not tgt then Logger.error("⚠  " .. err) ; return nil end
      return { targets={tgt}, is_item_env=true, n_items=1, ename=ename, tr_num=tgt.tr_num }

    else
      local tr_num = 0
      if p_track and p_track ~= 0 then
        tr_num = math.floor(reaper.GetMediaTrackInfo_Value(p_track, "IP_TRACKNUMBER"))
      end
      local v_prev, v_next = getNeighborValues(sel_env, ts_s, ts_e, 0)
      local pts            = MorphEngine.buildMorphSamples(v_prev, v_next)
      local tgt = {
        env=sel_env, ename=ename, parent_item=nil, parent_take=nil,
        time_offset=0, ts_s=ts_s, ts_e=ts_e,
        rel_s=ts_s, rel_e=ts_e, ts_len=ts_e-ts_s,
        pts=pts, tr_num=tr_num,
      }
      return { targets={tgt}, is_item_env=false, n_items=1, ename=ename, tr_num=tr_num }
    end
  end

  -- Path B: selected media items (multi-item support)
  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel > 0 then
    local targets      = {}
    local first_ename  = nil
    local mixed_ename  = false

    for i = 0, n_sel - 1 do
      local item             = reaper.GetSelectedMediaItem(0, i)
      local env, ename, take = findVisibleTakeEnv(item)
      if not env then
        local idx    = ReaperUtils.getItemIndexOnTrack(item)
        local ptrack = reaper.GetMediaItemInfo_Value(item, "P_TRACK")
        local tnum   = (ptrack and ptrack ~= 0)
          and math.floor(reaper.GetMediaTrackInfo_Value(ptrack, "IP_TRACKNUMBER")) or "?"
        Logger.error(string.format(
          "⚠  Item %s (TRK_%s) has no visible FX envelope — show one first",
          tostring(idx or "?"), tostring(tnum)))
        return nil
      end
      local tgt, err = buildItemTarget(env, ename, item, take, ts_s, ts_e, is_auto)
      if not tgt then Logger.error("⚠  " .. err) ; return nil end
      targets[#targets + 1] = tgt
      if not first_ename then first_ename = ename
      elseif ename ~= first_ename then mixed_ename = true end
    end

    local common_ename = mixed_ename and "mixed" or (first_ename or "?")
    return { targets=targets, is_item_env=true, n_items=n_sel,
             ename=common_ename, tr_num=0 }
  end

  -- Path C: track with no envelope selected
  if reaper.GetSelectedTrack(0, 0) then
    Logger.error("⚠  No env track selected (click on its lane)")
  else
    Logger.error("⚠  No track or media item selected")
  end
  return nil
end

-- ── Public API ───────────────────────────────────────────────

-- Writes morphed envelope points into the time selection (or cursor position).
function M.generateTimeSelection()
  local ctx = prepareWrite()
  if not ctx then return end

  reaper.PreventUIRefresh(1)
  local total_pts = 0
  for _, tgt in ipairs(ctx.targets) do
    reaper.DeleteEnvelopePointRangeEx(tgt.env, -1, tgt.rel_s - 0.0001, tgt.rel_e + 0.0001)
    EnvWriter.insertPoints(tgt.env, tgt.pts, tgt.rel_s, tgt.ts_len)
    reaper.Envelope_SortPointsEx(tgt.env, -1)
    if tgt.parent_item then reaper.UpdateItemInProject(tgt.parent_item) end
    total_pts = total_pts + #tgt.pts
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  local tag = makeTag({
    is_item_env = ctx.is_item_env,
    tr_num      = ctx.targets[1].tr_num,
    parent_item = ctx.targets[1].parent_item,
    n_items     = ctx.n_items,
  })
  Logger.ok(string.format("✔ [%s] %s | %.0f%%  %d pts",
    tag, ctx.ename, State.morph * 100, total_pts))
end

-- Creates a new automation item containing the morphed result.
-- Not supported on take/item-FX envelopes or the Tempo Map.
function M.generateAutomationItem()
  local ctx = prepareWrite()
  if not ctx then return end

  if ctx.is_item_env then
    Logger.error("⚠  Automation items not supported on item envelopes — use Envelope Points")
    return
  end

  local tgt = ctx.targets[1]
  tgt.pts = MorphEngine.buildMorphSamples(nil, nil)
  local _, tgt_ename = reaper.GetEnvelopeName(tgt.env)
  if tgt_ename == "Tempo map" then
    Logger.error("⚠  Automation items not supported on Tempo track — use Envelope Points")
    return
  end

  reaper.PreventUIRefresh(1)
  local ai_idx = EnvWriter.commitAutomationItem(tgt.env, tgt.pts, tgt.ts_s, tgt.ts_e)
  reaper.PreventUIRefresh(-1)

  reaper.UpdateArrange()

  if ai_idx >= 0 then
    local tag = makeTag({ is_item_env=false, tr_num=tgt.tr_num, n_items=1 })
    Logger.ok(string.format("✔ [%s] %s – AI inserted | %.0f%%  %d pts",
      tag, tgt.ename, State.morph * 100, #tgt.pts))
  else
    Logger.error("⚠  InsertAutomationItem failed")
  end
end

return M
