-- ============================================================
--   EnvelopeUtils.lua
--   REAPER envelope utilities: range detection, point reading,
--   normalization, frozen-sample evaluation.
--   All REAPER reads happen at snapshot time only.
-- ============================================================

local M = {}

local ScaleConverter = require("ScaleConverter")

-- ── Visibility check ─────────────────────────────────────────
-- Reads the envelope state chunk to check VIS and ACT flags.
-- This is more reliable than I_TCPH, which can be stale for take FX envelopes.
-- Falls back to I_TCPH if the chunk is unavailable.
function M.isVisible(env)
  if not env then return false end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if ok and chunk and #chunk > 0 then
    local vis = chunk:match("\nVIS (%d)")
    local act = chunk:match("\nACT (%d)")
    local vis_ok = not vis or tonumber(vis) == 1
    local act_ok = not act or tonumber(act) == 1
    return vis_ok and act_ok
  end
  local h = reaper.GetEnvelopeInfo_Value(env, "I_TCPH")
  return h ~= nil and h > 0
end

-- ── Envelope range ───────────────────────────────────────────

-- Returns (lo, hi, mode) from MINVAL/MAXVAL in the state chunk.
-- Falls back to per-name defaults when chunk values are missing.
function M.getRange(env)
  if not env then return 0, 1, 0 end
  local mode = reaper.GetEnvelopeScalingMode(env)
  if mode == 1 then return 0, 1, mode end

  local ok, chunk = reaper.GetEnvelopeStateChunk(env, "", false)
  if ok and chunk then
    local mn = chunk:match("\nMINVAL ([%-%.%d]+)")
    local mx = chunk:match("\nMAXVAL ([%-%.%d]+)")
    if mn and mx then
      local lo, hi = tonumber(mn), tonumber(mx)
      if hi - lo > 1e-9 then return lo, hi, mode end
    end
  end

  local _, name = reaper.GetEnvelopeName(env)
  name = name or ""
  if name == "Volume" or name == "Volume (Pre-FX)" then return 0, 1, 1 end
  if name == "Pan"    or name == "Pan (Pre-FX)"    then return -1, 1, mode end
  if name == "Width"  or name == "Width (Pre-FX)"  then return -1, 1, mode end
  return 0, 1, mode
end

-- Like getRange but also checks PARM_MIN/PARM_MAX.
-- PARM_MIN/PARM_MAX are the authoritative bounds for take FX envelopes
-- that lack MINVAL/MAXVAL in their chunk.
function M.resolveRange(env)
  local lo, hi, mode = M.getRange(env)
  if mode == 1 then return lo, hi, mode end
  local pmin = reaper.GetEnvelopeInfo_Value(env, "PARM_MIN")
  local pmax = reaper.GetEnvelopeInfo_Value(env, "PARM_MAX")
  if pmin and pmax and (pmax - pmin) > 1e-9 then
    lo = pmin ; hi = pmax
  end
  return lo, hi, mode
end

-- ── Converter detection ───────────────────────────────────────
-- Returns a ScaleConverter for Volume, Pitch, or Tempo envelopes.
-- Returns nil for generic envelopes (use resolveRange + linear mapping).
function M.detectConverter(env)
  if not env then return nil end
  local _, name = reaper.GetEnvelopeName(env)
  name = name or ""
  if name == "Volume" or name == "Volume (Pre-FX)" then
    return ScaleConverter.newVolume()
  end
  if name == "Pitch" then
    return ScaleConverter.newPitch()
  end
  if name == "Tempo map" or name == "Tempo" then
    return ScaleConverter.newTempo()
  end
  return nil
end

-- ── Raw point reading ────────────────────────────────────────
-- Reads all points from an automation item, trying four sources in order:
--   1. Points indexed directly on the AI
--   2. Points from the AI's pool
--   3. Base envelope points within the AI's time range
--   4. Envelope_Evaluate fallback (shape/tension unavailable)
-- Returns (pts_table, diagnostic_string).
function M.getRawPoints(ai_obj)
  local track = reaper.GetTrack(0, ai_obj.track_idx)
  if not track then return {}, "track not found" end
  local env = reaper.GetTrackEnvelope(track, ai_obj.env_idx)
  if not env then return {}, "envelope not found" end

  local idx   = ai_obj.ai_idx
  local n_ais = reaper.CountAutomationItems(env)
  if idx >= n_ais then return {}, "AI index out of bounds" end

  -- Source 1: direct AI points
  local n = reaper.CountEnvelopePointsEx(env, idx)
  if n and n > 0 then
    local pts = {}
    for i = 0, n - 1 do
      local ok, t, v, sh, tn_val = reaper.GetEnvelopePointEx(env, idx, i)
      if ok then pts[#pts+1] = { t=t, v=v, shape=sh or 0, tension=tn_val or 0 } end
    end
    if #pts > 0 then return pts, "direct(" .. #pts .. "pts)" end
  end

  -- Source 2: pool points
  local pool = reaper.GetSetAutomationItemInfo(env, idx, "D_POOL_ID", 0, false)
  if pool and pool >= 0 then
    local pidx = 0x10000000 + math.floor(pool)
    local n2   = reaper.CountEnvelopePointsEx(env, pidx)
    if n2 and n2 > 0 then
      local pts = {}
      for i = 0, n2 - 1 do
        local ok, t, v, sh, tn_val = reaper.GetEnvelopePointEx(env, pidx, i)
        if ok then pts[#pts+1] = { t=t, v=v, shape=sh or 0, tension=tn_val or 0 } end
      end
      if #pts > 0 then return pts, "pool(" .. #pts .. "pts)" end
    end
  end

  -- Source 3: base envelope points within the AI time range
  local pos, len = ai_obj.pos, ai_obj.len
  local nb = reaper.CountEnvelopePointsEx(env, -1)
  if nb and nb > 0 then
    local pts = {}
    for i = 0, nb - 1 do
      local ok, t, v, sh, tn_val = reaper.GetEnvelopePointEx(env, -1, i)
      if ok and t >= pos - 0.001 and t <= pos + len + 0.001 then
        pts[#pts+1] = { t=t, v=v, shape=sh or 0, tension=tn_val or 0 }
      end
    end
    if #pts > 0 then return pts, "base(" .. #pts .. "pts)" end
  end

  -- Source 4: Envelope_Evaluate fallback (no shape/tension)
  local pts = {}
  for s = 0, 8 do
    local ok2, v2 = reaper.Envelope_Evaluate(env, pos + len * s / 8, 0, 0)
    if ok2 and ok2 >= 0 then
      pts[#pts+1] = { t = pos + len * s / 8, v = v2, shape = 0, tension = 0 }
    end
  end
  if #pts > 0 then return pts, "eval(" .. #pts .. "pts)" end

  return {}, string.format("FAILED ai=%d n_ai=%d", idx, n_ais)
end

-- ── Normalization ────────────────────────────────────────────

-- Converts raw AI points to normalized [{tn, v, shape, tension}] with tn in [0,1].
-- Endpoint guards are added when the first/last point is not exactly at 0 or 1.
function M.normalisePts(pts, ai_pos, ai_len)
  if ai_len <= 0 or #pts == 0 then return {} end
  local t0     = pts[1].t
  local offset = (t0 > ai_len * 1.5 or t0 > 30) and ai_pos or 0
  local r = {}
  for _, p in ipairs(pts) do
    local tn = (p.t - offset) / ai_len
    -- Exclude the boundary point (tn >= 1.0) — it belongs to the base envelope,
    -- not to the AI itself.
    if tn >= -0.05 and tn < 1.0 - 1e-6 then
      r[#r+1] = {
        tn      = math.max(0, tn),
        v       = p.v,
        shape   = p.shape   or 0,
        tension = p.tension or 0,
      }
    end
  end
  if #r == 0 then return {} end
  table.sort(r, function(a, b) return a.tn < b.tn end)
  if r[1].tn > 0.001 then table.insert(r, 1, { tn=0, v=r[1].v, shape=0, tension=0 }) end
  -- No end guard at tn=1: points at the AI boundary are excluded in the loop above.
  return r
end

-- ── Evaluation ───────────────────────────────────────────────

-- REAPER shape IDs: 0=linear, 1=square, 2=slow start/end, 3=fast start,
--                   4=fast end, 5=bezier(tension).
local function interpShape(t, v0, v1, shape, tension)
  if shape == 1 then return v0 end
  local dv = v1 - v0
  local tc
  if     shape == 2 then tc = (1 - math.cos(t * math.pi)) * 0.5
  elseif shape == 3 then tc = 1 - (1 - t) * (1 - t)
  elseif shape == 4 then tc = t * t
  elseif shape == 5 then
    local base = t * t * (3 - 2 * t)
    tc = base + (tension or 0) * (t - base)
  else tc = t end
  return v0 + tc * dv
end

-- Evaluates a frozen_samples table at normalized position tn [0,1].
-- Uses linear interpolation between pre-sampled values.
function M.evalFrozenAI(frozen_samples, tn)
  if not frozen_samples or #frozen_samples < 2 then return 0.5 end
  local N = #frozen_samples - 1
  local f = math.max(0, math.min(N, tn * N))
  local i = math.floor(f)
  if i >= N then return frozen_samples[N + 1] end
  local t = f - i
  return frozen_samples[i + 1] + t * (frozen_samples[i + 2] - frozen_samples[i + 1])
end

-- Evaluates a point-selection snapshot at tn [0,1].
-- Uses frozen_samples when available (preserves native REAPER shapes including bezier).
-- Falls back to Lua interpolation with shape/tension from the point table.
function M.evalSel(sel, tn)
  if not sel then return 0.5 end
  if sel.frozen_samples then
    return M.evalFrozenAI(sel.frozen_samples, tn)
  end
  local pts = sel.pts
  if not pts or #pts == 0 then return 0.5 end
  if tn <= pts[1].tn    then return pts[1].v end
  if tn >= pts[#pts].tn then return pts[#pts].v end

  local lo_i, hi_i = 1, #pts
  while hi_i - lo_i > 1 do
    local mid = math.floor((lo_i + hi_i) / 2)
    if pts[mid].tn <= tn then lo_i = mid else hi_i = mid end
  end
  local span = pts[hi_i].tn - pts[lo_i].tn
  if span < 1e-12 then return pts[lo_i].v end
  local t = (tn - pts[lo_i].tn) / span
  return interpShape(t, pts[lo_i].v, pts[hi_i].v,
    pts[lo_i].shape or 0, pts[lo_i].tension or 0)
end

-- Generates n evenly-spaced normalized samples from a frozen_samples table.
-- Used to populate mini-graph display arrays.
function M.sampleFrozenNorm(frozen_samples, n)
  if not frozen_samples or #frozen_samples < 2 then return {} end
  local v     = {}
  local denom = math.max(1, n - 1)
  for i = 0, n - 1 do
    v[#v + 1] = M.evalFrozenAI(frozen_samples, i / denom)
  end
  return v
end

-- ── Range utilities ──────────────────────────────────────────

-- Returns (lo, hi) for a [{v=...}] point table.
function M.computeVRange(pts)
  if #pts == 0 then return 0, 1 end
  local lo, hi = math.huge, -math.huge
  for _, p in ipairs(pts) do
    if p.v < lo then lo = p.v end
    if p.v > hi then hi = p.v end
  end
  if hi - lo < 1e-6 then return lo - 0.5, lo + 0.5 end
  return lo, hi
end

-- Clamps and normalizes v from [lo, hi] to [0, 1].
function M.vnorm(v, lo, hi)
  if hi <= lo then return 0.5 end
  return math.max(0, math.min(1, (v - lo) / (hi - lo)))
end

return M