-- ============================================================
--   RANDWrite.lua
--   REAPER writes: resolves target, computes grid divisions,
--   converts normalized values, inserts points or AI.
-- ============================================================

local M = {}

local Logger          = require("Logger")
local GeneratorState  = require("RANDState")
local GeneratorConfig = require("RANDConfig")
local Generator       = require("Generator")
local EnvUtils        = require("EnvelopeUtils")
local EnvConvert      = require("EnvConvert")
local GridUtils       = require("GridUtils")
local EnvWriter       = require("EnvWriter")

local getGridTimes     = GridUtils.getGridTimes
local getGridDivisions = GridUtils.getGridDivisions
local snapToGrid       = GridUtils.snapToGrid

-- ── Frame-state cache (for preview dirty detection) ───────────
local _last_ts_s      = -1
local _last_ts_e      = -1
local _last_division  = -1
local _last_n_items   = -1
local _last_item_ptr  = nil

-- ── Value conversion (via CommonFunction/EnvConvert) ────────
local toEnvValue   = EnvConvert.toEnvValue
local fromEnvValue = EnvConvert.fromEnvValue

-- ── Boundary reading ─────────────────────────────────────────
local function readBoundaryValues(env, ts_s, ts_e)
  local conv          = EnvUtils.detectConverter(env)
  local lo, hi, mode  = EnvUtils.resolveRange(env)
  local v_start, v_end
  local ok1, r1 = reaper.Envelope_Evaluate(env, ts_s, 0, 0)
  if ok1 and ok1 >= 0 then v_start = fromEnvValue(r1, conv, lo, hi, mode) end
  local ok2, r2 = reaper.Envelope_Evaluate(env, ts_e, 0, 0)
  if ok2 and ok2 >= 0 then v_end   = fromEnvValue(r2, conv, lo, hi, mode) end
  return v_start, v_end
end

-- ── Params from State ─────────────────────────────────────────
local function buildParams(amp_lo, amp_hi)
  local S = GeneratorState
  return {
    seed        = S.seed,
    shape_seed  = S.shape_seed,
    n_points    = S.num_points,
    pts_per_div = S.pts_per_div,
    shape       = S.shape,
    tension     = S.tension,
    amp_lo      = amp_lo,
    amp_hi      = amp_hi,
    amp_free    = S.amp_free,
    quant_steps = S.quant_steps,
  }
end

-- ── Effective amplitude range (preset + scale/offset sliders) ─
-- Mirrors the calculation in SLK_RandomGenerator.lua so that
-- what is previewed is exactly what is written.
--   amp_scale  [0,1]  : shrinks the half-range from the centre
--   amp_offset [-1,1] : shifts the centre (±1 = ±100% bipolar)
local function effectiveAmpRange(range)
  local S          = GeneratorState
  local amp_scale  = S.amp_scale  or 1.0
  local amp_offset = S.amp_offset or 0.0
  local center     = (range.lo + range.hi) * 0.5
  local half       = (range.hi - range.lo) * 0.5 * amp_scale
  local shift      = amp_offset * 0.5
  local eff_lo     = math.max(0.0, math.min(1.0, center - half + shift))
  local eff_hi     = math.max(0.0, math.min(1.0, center + half + shift))
  return eff_lo, eff_hi
end

-- ── Public: envelope points ───────────────────────────────────
function M.generateEnvelopePoints()
  local S      = GeneratorState
  local env, ts_s, ts_e, time_offset = EnvWriter.resolveTarget()
  if not env then return end

  local range        = GeneratorConfig.AMP_RANGES[S.amp_range] or GeneratorConfig.AMP_RANGES[1]
  local eff_lo, eff_hi = effectiveAmpRange(range)
  local params       = buildParams(eff_lo, eff_hi)

  -- In grid mode, snap the time selection boundaries to the nearest grid lines
  if S.gen_mode == "grid" then
    ts_s = snapToGrid(ts_s)
    ts_e = snapToGrid(ts_e)
  end

  local pts
  if S.gen_mode == "grid" then
    pts = Generator.generateGrid(params, getGridDivisions(ts_s, ts_e))
  else
    pts = Generator.generateFree(params)
  end

  local ts_len = ts_e - ts_s
  -- Take envelopes use times relative to item start (time_offset).
  -- Track envelopes: time_offset = 0, so rel_s == ts_s.
  local rel_s  = ts_s - time_offset
  local rel_e  = ts_e - time_offset

  local conv         = EnvUtils.detectConverter(env)
  local lo, hi, mode = EnvUtils.resolveRange(env)
  local v_start, v_end = readBoundaryValues(env, rel_s, rel_e)

  local GUARD = math.max(0.001, ts_len * 0.001)

  reaper.PreventUIRefresh(1)
  reaper.DeleteEnvelopePointRangeEx(env, -1, rel_s - 0.0001, rel_e + 0.0001)

  if v_start then
    reaper.InsertEnvelopePointEx(env, -1, rel_s,
      toEnvValue(v_start, conv, lo, hi, mode), 0, 0, false, true)
  end
  if v_end then
    reaper.InsertEnvelopePointEx(env, -1, rel_e,
      toEnvValue(v_end, conv, lo, hi, mode), 0, 0, false, true)
  end

  EnvWriter.insertPoints(env, pts, rel_s + GUARD, ts_len - 2 * GUARD)

  reaper.Envelope_SortPointsEx(env, -1)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  Logger.ok(string.format("✔ %d envelope points written", #pts + 2))
end

-- ── Public: automation item ───────────────────────────────────
function M.generateAutomationItem()
  local S      = GeneratorState
  local env, ts_s, ts_e, time_offset = EnvWriter.resolveTarget()
  if not env then return end
  if time_offset ~= 0 then
    Logger.error("⚠  Automation items not supported on take FX envelopes — use Envelope Points") ; return
  end

  local _, en = reaper.GetEnvelopeName(env)
  if en == "Tempo map" then
    Logger.error("⚠  Automation items not supported on Tempo track") ; return
  end
  local range        = GeneratorConfig.AMP_RANGES[S.amp_range] or GeneratorConfig.AMP_RANGES[1]
  local eff_lo, eff_hi = effectiveAmpRange(range)
  local params       = buildParams(eff_lo, eff_hi)

  -- Snap time selection to grid in grid mode
  if S.gen_mode == "grid" then
    ts_s = snapToGrid(ts_s)
    ts_e = snapToGrid(ts_e)
  end

  local pts
  if S.gen_mode == "grid" then
    pts = Generator.generateGrid(params, getGridDivisions(ts_s, ts_e))
  else
    pts = Generator.generateFree(params)
  end

  reaper.PreventUIRefresh(1)
  local ai_idx = EnvWriter.commitAutomationItem(env, pts, ts_s, ts_e)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()

  if ai_idx >= 0 then
    Logger.ok(string.format("✔ Automation item inserted — %d pts", #pts))
  else
    Logger.error("⚠  InsertAutomationItem failed")
  end
end

-- ── Public: current grid divisions ───────────────────────────
function M.getCurrentDivisions()
  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  if ts_e - ts_s < 0.01 then return {{ lo=0.0, hi=1.0 }} end
  return getGridDivisions(ts_s, ts_e)
end

-- ── Public: preview refresh ───────────────────────────────────
-- Uses EnvWriter.getEffectiveRange() so the preview always matches what will be written:
-- - item selected + ts within item → preview on clamped ts (snapped if grid)
-- - item selected + no ts          → preview on full item bounds (snapped if grid)
-- - ts only                        → preview on ts (snapped if grid)
-- In grid mode, also detects external changes (ts or grid division) each frame.
function M.refreshPreview(State, params)
  -- Detect changes every frame regardless of mode:
  -- item selection, time selection, grid division (grid mode only)
  do
    local n_items    = reaper.CountSelectedMediaItems(0)
    local item_ptr   = n_items > 0 and reaper.GetSelectedMediaItem(0, 0) or nil
    local ts_s_raw, ts_e_raw = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    local _, division        = reaper.GetSetProjectGrid(0, false)
    if n_items   ~= _last_n_items
    or item_ptr  ~= _last_item_ptr
    or ts_s_raw  ~= _last_ts_s
    or ts_e_raw  ~= _last_ts_e
    or (State.gen_mode == "grid" and division ~= _last_division) then
      _last_n_items, _last_item_ptr   = n_items, item_ptr
      _last_ts_s, _last_ts_e          = ts_s_raw, ts_e_raw
      _last_division                  = division
      State.preview_dirty = true
    end
  end

  if not State.preview_dirty then return end
  State.preview_dirty = false

  -- Resolve the effective range the same way resolveTarget will
  local eff_s, eff_e = EnvWriter.getEffectiveRange()

  local divisions
  if State.gen_mode == "grid" then
    if eff_s then
      local snapped_s = snapToGrid(eff_s)
      local snapped_e = snapToGrid(eff_e)
      if snapped_e - snapped_s > 0.01 then
        divisions = getGridDivisions(snapped_s, snapped_e)
      end
    end
    -- No valid range or snap collapsed to zero: show a single grid division
    if not divisions then
      divisions = {{ lo=0.0, hi=1.0 }}
    end
  end
  -- Free mode: always generate preview regardless of range

  if State.gen_mode == "free" then
    State.gen_pts = Generator.generateFree(params)
  else
    State.gen_pts = Generator.generateGrid(params, divisions)
  end

  -- Rebuild preview (with bezier boundary re-read below)
  M.rebuildPreviewCurve(State, params)
end

-- ── Public: rebuild preview curve ────────────────────────────
-- Called by refreshPreview after gen_pts are ready, AND directly each frame
-- when shape==5 so that bezier edge segments always reflect the current
-- envelope values at the range boundaries — even if gen_pts didn't change.
function M.rebuildPreviewCurve(State, params)
  local preview_pts = State.gen_pts
  if #preview_pts == 0 then
    State.preview_pts = {}
    return
  end

  -- For Bezier: inject ghost boundary neighbors so edge segments
  -- render with the real envelope values. Re-read every call (cheap).
  if params.shape == 5 then
    local env = reaper.GetSelectedEnvelope(0)
    if env then
      local eff_s, eff_e, time_offset = EnvWriter.getEffectiveRange()
      if eff_s then
        local rel_s       = eff_s - (time_offset or 0)
        local rel_e       = eff_e - (time_offset or 0)
        local conv         = EnvUtils.detectConverter(env)
        local lo, hi, mode = EnvUtils.resolveRange(env)
        local range        = hi - lo ; if math.abs(range) < 1e-9 then range = 1 end

        local function normFromEnv(t_rel)
          local ok, v_raw = reaper.Envelope_Evaluate(env, t_rel, 0, 0)
          if not (ok and ok >= 0) then return nil end
          if conv then
            if conv.type == "volume" then return conv:fromEnvelope(v_raw, mode)
            else                          return conv:fromNative(v_raw) end
          end
          local vf = reaper.ScaleFromEnvelopeMode(mode, v_raw)
          if mode == 1 then return vf end
          return (vf - lo) / range
        end

        local v_before = normFromEnv(rel_s)
        local v_after  = normFromEnv(rel_e)
        local aug = {}
        if v_before then aug[#aug+1] = { tn=-0.001, v=v_before, shape=5, tension=params.tension } end
        for _, p in ipairs(State.gen_pts) do aug[#aug+1] = p end
        if v_after  then aug[#aug+1] = { tn=1.001,  v=v_after,  shape=5, tension=params.tension } end
        preview_pts = aug
      end
    end
  end

  State.preview_pts = Generator.buildPreview(preview_pts)
end

return M