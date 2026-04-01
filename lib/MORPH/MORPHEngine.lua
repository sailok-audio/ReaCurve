-- ============================================================
--   MORPHEngine.lua
--   Pure calculation engine: point reduction (shapeFit),
--   morph interpolation, preview sample generation.
--   No REAPER writes. Callers update State from return values.
-- ============================================================

local M = {}

local EnvUtils = require("EnvelopeUtils")
local State    = require("MORPHState")
local Config   = require("MORPHConfig")

-- ── Shape candidates for shapeFit ────────────────────────────
-- Each candidate maps a normalized t [0,1] to a curve position [0,1].
local CANDIDATES = {
  { id=0, fn = function(t) return t end },                          -- linear
  { id=2, fn = function(t) return t*t*(3 - 2*t) end },             -- slow start/end
  { id=3, fn = function(t) return 2*t - t*t end },                 -- fast start
  { id=4, fn = function(t) return t*t end },                       -- fast end
}

-- ── Segment error ────────────────────────────────────────────

-- Returns the maximum absolute error produced by fn over samples[lo_i..hi_i].
local function segError(samples, lo_i, hi_i, fn)
  local lo, hi = samples[lo_i], samples[hi_i]
  local span   = hi.tn - lo.tn
  if span < 1e-12 then return 0 end
  local max_err = 0
  for i = lo_i + 1, hi_i - 1 do   -- endpoints are always exact, skip them
    local t  = (samples[i].tn - lo.tn) / span
    local sv = fn(t)
    local e  = math.abs(samples[i].v - (lo.v + sv * (hi.v - lo.v)))
    if e > max_err then max_err = e end
  end
  return max_err
end

-- Returns (best_candidate, best_error) for a segment [lo_i, hi_i].
local function bestCandidate(samples, lo_i, hi_i)
  local best, best_err = CANDIDATES[1], math.huge
  for _, c in ipairs(CANDIDATES) do
    local err = segError(samples, lo_i, hi_i, c.fn)
    if err < best_err then best_err = err ; best = c end
  end
  return best, best_err
end

-- ── shapeFit ─────────────────────────────────────────────────
-- Reduces a dense [{tn, v}] sample array to a minimal set of
-- envelope-compatible control points [{tn, v, shape, tension}]
-- whose maximum reconstruction error is ≤ threshold.
-- Pass 1: greedy forward scan.
-- Pass 2: backward merge of redundant points.
function M.shapeFit(samples, threshold)
  if #samples <= 2 then
    local out = {}
    for _, p in ipairs(samples) do
      out[#out+1] = { tn=p.tn, v=p.v, shape=0, tension=0 }
    end
    return out
  end

  -- Pass 1: greedy construction
  local initial = {}
  local start   = 1
  while start < #samples do
    local best_end  = start + 1
    local best_cand = CANDIDATES[1]
    for hi = start + 1, #samples do
      local cand, err = bestCandidate(samples, start, hi)
      if err <= threshold then
        best_end  = hi
        best_cand = cand
      else break end
    end
    initial[#initial+1] = {
      idx     = start,
      tn      = samples[start].tn,
      v       = samples[start].v,
      shape   = best_cand.id,
      tension = 0,
    }
    start = best_end
  end
  initial[#initial+1] = {
    idx     = #samples,
    tn      = samples[#samples].tn,
    v       = samples[#samples].v,
    shape   = 0,
    tension = 0,
  }

  -- Pass 2: merge redundant points
  local i = 2
  while i < #initial do
    local prev = initial[i - 1]
    local next = initial[i + 1]
    local cand, err = bestCandidate(samples, prev.idx, next.idx)
    if err <= threshold then
      table.remove(initial, i)
      prev.shape = cand.id
    else
      i = i + 1
    end
  end

  local out = {}
  for _, p in ipairs(initial) do
    out[#out+1] = { tn=p.tn, v=p.v, shape=p.shape, tension=0 }
  end
  return out
end

-- ── Slot evaluation ──────────────────────────────────────────

-- Evaluates slot n at normalized position tn [0,1].
-- Returns a value in [0,1]. Reads from frozen data only (no REAPER calls).
function M.evalSlotNorm(n, tn)
  local stype = (n == 1) and State.slot1_type or State.slot2_type
  if stype == "sel" then
    local s = (n == 1) and State.sel1 or State.sel2
    return EnvUtils.evalSel(s, tn)
  elseif stype == "ai" then
    local obj = (n == 1) and State.ai1 or State.ai2
    if not obj or not obj.frozen_samples then return 0.5 end
    return EnvUtils.evalFrozenAI(obj.frozen_samples, tn)
  end
  return 0.5
end

-- ── buildMorphSamples ─────────────────────────────────────────
-- Builds the final morphed point list for writing to REAPER.
-- v_prev / v_next : optional boundary values for edge continuity.
-- Returns a [{tn, v, shape, tension}] table and updates State.last_stats.
function M.buildMorphSamples(v_prev, v_next)
  local tune    = Config.TUNE
  local max_len = math.max(State.getSlotLen(1), State.getSlotLen(2), 1)

  local N = math.min(
    math.max(1, tune.max_samples),
    math.max(64, math.floor(max_len * math.max(10, tune.samples_per_sec)))
  )

  local s       = {}
  local lo, hi  = math.huge, -math.huge
  for i = 0, N do
    local tn  = i / N
    local v   = M.evalSlotNorm(1, tn) + State.morph * (M.evalSlotNorm(2, tn) - M.evalSlotNorm(1, tn))
    s[#s+1]   = { tn=tn, v=v }
    if v < lo then lo = v end
    if v > hi then hi = v end
  end

  local range_final = math.max(hi - lo, 1e-6)

  if v_prev then
    s[1].v = v_prev
    if v_prev < lo then lo = v_prev ; range_final = math.max(hi-lo, 1e-6) end
    if v_prev > hi then hi = v_prev ; range_final = math.max(hi-lo, 1e-6) end
  end
  if v_next then
    s[#s].v = v_next
    if v_next < lo then lo = v_next ; range_final = math.max(hi-lo, 1e-6) end
    if v_next > hi then hi = v_next ; range_final = math.max(hi-lo, 1e-6) end
  end

  local threshold = math.max(0.001, range_final * (tune.threshold_pct / 100))

  local t_start = reaper.time_precise()
  local fitted  = M.shapeFit(s, threshold)
  local t_end   = reaper.time_precise()

  -- Compute actual reconstruction error for diagnostics
  local max_real_err = 0
  for _, sp in ipairs(s) do
    local fit_v = sp.v
    for fi = 1, #fitted - 1 do
      local fa, fb = fitted[fi], fitted[fi + 1]
      if sp.tn >= fa.tn and sp.tn <= fb.tn then
        local span = fb.tn - fa.tn
        if span > 1e-12 then
          local t  = (sp.tn - fa.tn) / span
          local id = fa.shape
          local sv
          if     id == 0 then sv = t
          elseif id == 2 then sv = t*t*(3-2*t)
          elseif id == 3 then sv = 2*t - t*t
          elseif id == 4 then sv = t*t
          else sv = t end
          fit_v = fa.v + sv * (fb.v - fa.v)
        end
        break
      end
    end
    local e = math.abs(sp.v - fit_v)
    if e > max_real_err then max_real_err = e end
  end

  State.last_stats.pts_in      = #s
  State.last_stats.pts_out     = #fitted
  State.last_stats.time_ms     = (t_end - t_start) * 1000
  State.last_stats.max_err_pct = (max_real_err / range_final) * 100
  State.last_stats.ratio       = #s / math.max(1, #fitted)
  State.last_fitted            = fitted

  return fitted
end

-- ── Catmull-Rom smoothing for display ────────────────────────
-- Subdivides control points for smooth display rendering.
-- Jumps larger than STEP_THRESHOLD are treated as square discontinuities
-- and rendered as horizontal + near-vertical segments.
local STEP_THRESHOLD = 0.05

function M.smoothCurvePoints(pts, sub)
  if #pts < 3 then return pts end
  sub = sub or 3
  local out = {}
  for i = 1, #pts - 1 do
    local p0 = pts[math.max(1, i - 1)]
    local p1 = pts[i]
    local p2 = pts[i + 1]
    local p3 = pts[math.min(#pts, i + 2)]
    out[#out+1] = p1

    if math.abs(p2.v - p1.v) > STEP_THRESHOLD then
      -- Square discontinuity: insert a bridge point just before the jump
      out[#out+1] = { tn = p1.tn + (p2.tn - p1.tn) * 0.98, v = p1.v }
    else
      -- Guard against overshoot when a neighbour is across a step
      local p0v = (math.abs(p1.v - p0.v) > STEP_THRESHOLD) and p1.v or p0.v
      local p3v = (math.abs(p3.v - p2.v) > STEP_THRESHOLD) and p2.v or p3.v
      for s = 1, sub - 1 do
        local t  = s / sub
        local t2 = t * t
        local t3 = t2 * t
        local v  = 0.5 * (
          (2 * p1.v) +
          (-p0v + p2.v)             * t  +
          (2*p0v - 5*p1.v + 4*p2.v - p3v) * t2 +
          (-p0v + 3*p1.v - 3*p2.v + p3v)  * t3
        )
        out[#out+1] = {
          tn = p1.tn + (p2.tn - p1.tn) * t,
          v  = math.max(0, math.min(1, v)),
        }
      end
    end
  end
  out[#out+1] = pts[#pts]
  return out
end

-- ── Preview generation ────────────────────────────────────────

-- Fast preview update — used during drag. Skips shapeFit.
-- Uses the same adaptive N as refreshPreview for consistent curve density.
function M.refreshPreviewFast()
  if not State.slotReady(1) or not State.slotReady(2) then
    State.prev_samples = {} ; return
  end
  local tune    = Config.TUNE
  local max_len = math.max(State.getSlotLen(1), State.getSlotLen(2), 1)
  local N = math.min(
    math.max(1, tune.max_samples),
    math.max(64, math.floor(max_len * math.max(10, tune.samples_per_sec)))
  )
  local s = {}
  for i = 0, N do
    local tn  = i / N
    local v1n = M.evalSlotNorm(1, tn)
    local v2n = M.evalSlotNorm(2, tn)
    s[#s+1] = { tn=tn, v = v1n + State.morph * (v2n - v1n) }
  end
  State.prev_samples = s
end

-- Full preview update — runs shapeFit. Skipped when cache key is unchanged.
function M.refreshPreview()
  local k1  = State.ai1  and (State.ai1.track_idx..":"..State.ai1.env_idx..":"..State.ai1.ai_idx)  or "-"
  local k2  = State.ai2  and (State.ai2.track_idx..":"..State.ai2.env_idx..":"..State.ai2.ai_idx)  or "-"
  local ks1 = State.sel1 and tostring(#(State.sel1.pts or {})) or "-"
  local ks2 = State.sel2 and tostring(#(State.sel2.pts or {})) or "-"
  local key = string.format("%s|%s|%.5f|%d|%d|%s|%s|%s|%s",
    tostring(State.slot1_type), tostring(State.slot2_type),
    State.morph, Config.active_preset, Config.max_samples_idx,
    k1, k2, ks1, ks2)

  if key == State.prev_cache_key then return end
  State.prev_cache_key = key

  if not State.slotReady(1) or not State.slotReady(2) then
    State.prev_samples={} ; State.prev_fitted={} ; State.prev_fitted_stable={} ; return
  end

  local tune    = Config.TUNE
  local max_len = math.max(State.getSlotLen(1), State.getSlotLen(2), 1)
  local N = math.min(
    math.max(1, tune.max_samples),
    math.max(64, math.floor(max_len * math.max(10, tune.samples_per_sec)))
  )

  local s   = {}
  local slo, shi = math.huge, -math.huge
  for i = 0, N do
    local tn  = i / N
    local v1n = M.evalSlotNorm(1, tn)
    local v2n = M.evalSlotNorm(2, tn)
    local v   = v1n + State.morph * (v2n - v1n)
    s[#s+1]   = { tn=tn, v=v }
    if v < slo then slo=v end
    if v > shi then shi=v end
  end

  local range_final = math.max(shi - slo, 1e-6)
  local threshold   = math.max(0.001, range_final * (tune.threshold_pct / 100))

  State.prev_samples       = s
  State.prev_fitted        = M.shapeFit(s, threshold)
  State.prev_fitted_stable = State.prev_fitted
end

return M
