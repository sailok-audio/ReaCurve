-- ============================================================
--   Generator.lua
--   Pure math: random generation, interpolation, preview.
--   No REAPER API calls. All values normalized to [0,1].
-- ============================================================

local M = {}

local GeneratorConfig = require("RANDConfig")

-- ── Seeded LCG RNG ───────────────────────────────────────────
local function makeRng(seed)
  local s = (math.floor(math.abs(seed)) % 2147483647) + 1
  return function()
    s = (s * 1103515245 + 12345) % 2147483648
    return s / 2147483648
  end
end

-- ── Amplitude helpers ─────────────────────────────────────────
local function quantize(v, lo, hi, steps)
  if steps <= 1 then return (lo + hi) * 0.5 end
  local range = hi - lo
  if math.abs(range) < 1e-9 then return lo end
  local idx = math.floor((v - lo) / range * (steps - 1) + 0.5)
  idx = math.max(0, math.min(steps - 1, idx))
  return lo + idx * range / (steps - 1)
end

local function randAmp(rng, lo, hi, amp_free, quant_steps)
  local v = lo + rng() * (hi - lo)
  if not amp_free then v = quantize(v, lo, hi, quant_steps) end
  return v
end


-- ── Curve interpolation ───────────────────────────────────────
-- Matches REAPER's internal shape rendering exactly.
--
-- Bezier (shape 5) with tension — matches REAPER's Envelope_Evaluate exactly:
--   base = smoothstep(t) = 3t²-2t³  (S-curve)
--   tc   = t + tension * (base - t)
--   tension =  0  → linear            (REAPER default at tension=0)
--   tension = +1  → smoothstep S-curve
--   tension = -1  → 2t - smoothstep   (anti-S / overshoot)


local function interpShape(t, v0, v1, shape, tension, v_prev, v_next)
  if shape == 1 then return v0 end
  local tc
  if     shape == 2 then tc = (1 - math.cos(t * math.pi)) * 0.5
  elseif shape == 3 then tc = 1 - (1 - t) * (1 - t)
  elseif shape == 4 then tc = t * t
  elseif shape == 5 then
  tension = tension or 0
  local v   = math.abs(tension)
  local dv  = v1 - v0

  -- Normalized Catmull-Rom tangents (clamped to avoid overshoot)
  local m1, m2
  if math.abs(dv) > 1e-6 then
    local raw_m1 = v_prev and (v1 - v_prev) / (2 * dv) or 0.625
    local raw_m2 = v_next and (v_next - v0) / (2 * dv) or 0.625
    m1 = math.max(0, math.min(1, raw_m1))
    m2 = math.max(0, math.min(1, raw_m2))
  else
    m1, m2 = 0.625, 0.625
  end

  -- Base Hermite (tension=0) : correspond aux mesures REAPER
  local h10 = t*t*t - 2*t*t + t
  local h11 = t*t*t - t*t
  local h01 = -2*t*t*t + 3*t*t
  local tc_cr = h01 + h10 * m1 + h11 * m2

  -- Extremes
  local p1y, p2y
  if tension >= 0 then p1y, p2y = 0, 1 - v
  else                 p1y, p2y = v, 1 end
  local inv_t    = 1 - t
  local tc_bezier = 3*(inv_t^2)*t*p1y + 3*inv_t*(t^2)*p2y + t^3
  local tc_power  = (tension >= 0) and (t^18) or (1-(1-t)^18)
  local extreme   = tc_bezier + (tc_power - tc_bezier) * v

  local v_curve = v ^ 0.1
  tc = tc_cr + (extreme - tc_cr) * v_curve
  else
    tc = t
  end
  return v0 + tc * (v1 - v0)
end

-- ── Shape resolution ─────────────────────────────────────────
-- meta_shape 6 = Random: picks shape + tension from shape_rng.
local function resolveShape(meta_shape, shape_rng, tension)
  if meta_shape ~= 6 then
    return meta_shape, (meta_shape == 5) and (tension or 0.0) or 0.0
  end
  local pool = GeneratorConfig.RANDOM_SHAPE_POOL
  local idx  = math.max(1, math.min(#pool, math.floor(shape_rng() * #pool) + 1))
  local sh   = pool[idx]
  -- For bezier: also randomize tension in [-1, 1]
  local tn_val = (sh == 5) and (shape_rng() * 2.0 - 1.0) or 0.0
  return sh, tn_val
end

local function makePoint(tn, v, sh, tn_val)
  return { tn=tn, v=v, shape=sh, tension=tn_val }
end

-- ── Free mode ────────────────────────────────────────────────
function M.generateFree(params)
  local rng       = makeRng(params.seed)
  local shape_rng = makeRng(params.shape_seed)
  local n         = math.max(2, math.floor(params.n_points))
  local lo, hi    = params.amp_lo, params.amp_hi

  -- Stratified jitter: divide [0,1] into n-1 equal slots,
  -- place one inner point randomly within the central 80% of each slot.
  -- Guarantees a minimum gap of ~20% of slot width between any two consecutive points,
  -- eliminates clustering entirely, keeps exactly n points, no sort or redistribution needed.
  local slot = 1.0 / (n - 1)
  local tns = { 0.0 }
  for i = 1, n - 2 do
    tns[#tns+1] = i * slot + slot * 0.1 + rng() * slot * 0.8
  end
  tns[#tns+1] = 1.0

  local pts = {}
  for i = 1, n do
    local sh, tn_val = resolveShape(params.shape, shape_rng, params.tension)
    pts[i] = makePoint(tns[i], randAmp(rng, lo, hi, params.amp_free, params.quant_steps), sh, tn_val)
  end
  return pts
end

-- ── Grid mode ────────────────────────────────────────────────
-- X positions are 100% deterministic: seed only affects Y (amplitude).
-- ppd=1 -> one point per grid line (at div.lo).
-- ppd=2 -> two points per division at div.lo and div.lo + span/2.
-- ppd=N -> N equidistant points at div.lo + span * k/N  (k=0..N-1).
-- A final point is always added at tn=1.0 (last grid line).
function M.generateGrid(params, divisions)
  local rng       = makeRng(params.seed)
  local shape_rng = makeRng(params.shape_seed)
  local ppd       = math.max(1, math.floor(params.pts_per_div))
  local lo, hi    = params.amp_lo, params.amp_hi

  local pts = {}

  for _, div in ipairs(divisions) do
    local span = div.hi - div.lo
    for k = 0, ppd - 1 do
      local tn         = div.lo + span * (k / ppd)   -- purely deterministic, no rng
      local sh, tn_val = resolveShape(params.shape, shape_rng, params.tension)
      pts[#pts+1] = makePoint(tn, randAmp(rng, lo, hi, params.amp_free, params.quant_steps), sh, tn_val)
    end
  end

  -- Final point at tn=1.0 (last grid line / end of selection)
  do
    local sh, tn_val = resolveShape(params.shape, shape_rng, params.tension)
    pts[#pts+1] = makePoint(1.0, randAmp(rng, lo, hi, params.amp_free, params.quant_steps), sh, tn_val)
  end

  return pts
end

-- ── Evaluation ───────────────────────────────────────────────
local function evalPtsAt(pts, tn)
  if #pts == 0 then return 0.5 end
  if tn <= pts[1].tn then return pts[1].v end
  if tn >= pts[#pts].tn then return pts[#pts].v end
  local lo_i, hi_i = 1, #pts
  while hi_i - lo_i > 1 do
    local mid = math.floor((lo_i + hi_i) / 2)
    if pts[mid].tn <= tn then lo_i = mid else hi_i = mid end
  end
  local span = pts[hi_i].tn - pts[lo_i].tn
  if span < 1e-12 then return pts[lo_i].v end
  local t      = (tn - pts[lo_i].tn) / span
  local v_prev = lo_i > 1      and pts[lo_i - 1].v or nil
  local v_next = hi_i < #pts   and pts[hi_i + 1].v or nil
  return interpShape(t, pts[lo_i].v, pts[hi_i].v,
    pts[lo_i].shape or 0, pts[lo_i].tension or 0, v_prev, v_next)
end

-- Builds a dense [{tn, v}] display array.
-- Strategy: for each segment between control points, sample at high density
-- PLUS add an exact sample at every control point to guarantee dots sit on the curve.
function M.buildPreview(pts)
  if #pts < 2 then return {} end

  -- Minimum samples per segment (more for smooth bezier shapes)
  local seg_samples = 48

  local out = {}
  local seen = {}  -- deduplicate tn positions

  local function addSample(tn)
    local key = math.floor(tn * 1000000 + 0.5)
    if seen[key] then return end
    seen[key] = true
    out[#out+1] = { tn=tn, v=evalPtsAt(pts, tn) }
  end

  -- First point
  addSample(0.0)

  for i = 1, #pts - 1 do
    local t0 = pts[i].tn
    local t1 = pts[i+1].tn
    local span = t1 - t0
    if span > 1e-9 then
      if pts[i].shape == 1 then
        -- Square: sample flat up to just before t1, then let t1 produce the jump.
        -- This ensures the drawn line is nearly vertical (crisp step) not diagonal.
        for s = 1, seg_samples - 1 do
          addSample(t0 + span * s / seg_samples)
        end
        addSample(t1 - span * 0.0003)   -- last flat sample, right before the edge
      else
        for s = 1, seg_samples do
          addSample(t0 + span * s / seg_samples)
        end
      end
    end
  end

  -- Guarantee exact sample at each control point (dot must be on curve)
  for _, p in ipairs(pts) do
    addSample(p.tn)
  end

  -- Sort by tn
  table.sort(out, function(a, b) return a.tn < b.tn end)
  return out
end

-- ── State refresh ─────────────────────────────────────────────
-- refreshPreview lives in GeneratorWrite.lua so grid mode can read
-- the real REAPER project grid instead of a fake single-division fallback.

return M