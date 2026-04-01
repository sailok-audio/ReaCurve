-- ============================================================
--   SCULPTEngine.lua
--   Pure math transform engine — no REAPER writes.
--
--   Exports:
--     M.computeTransforms(pts, t_first, t_last)
-- ============================================================

local M = {}

local r = reaper
local S = require("SCULPTState")

-- ── Right-boundary helper ─────────────────────────────────────
-- Returns the time of the first unselected point after t_last (main env)
-- or the end position of the automation item (AI mode).
-- Read-only REAPER calls — safe in a pure engine module.
local function getRightBoundary(env, ai_idx, t_last)
  if ai_idx == -1 then
    -- Main envelope case: find the first unselected point after t_last
    local n = r.CountEnvelopePointsEx(env, -1)
    for i = 0, n - 1 do
      local ok, t, _, _, _, sel = r.GetEnvelopePointEx(env, -1, i)
      if ok and t > t_last + 0.0001 and not sel then
        return t
      end
    end
  else
    -- Automation item case: the boundary is the end of the AI itself
    local ai_pos = r.GetSetAutomationItemInfo(env, ai_idx, "D_POSITION", 0, false)
    local ai_len = r.GetSetAutomationItemInfo(env, ai_idx, "D_LENGTH", 0, false)
    return ai_pos + ai_len
  end

  -- If nothing is found, set a default margin (e.g., +10 seconds)
  return t_last + 10.0
end

-- ── Pure transform engine ─────────────────────────────────────
function M.computeTransforms(pts, t_first, t_last)
  if not pts or #pts == 0 then return {} end
  local t_range = (t_last - t_first)
  if t_range < 1e-9 then t_range = 1 end

  local shift = S.baseline * 0.5

  -- Pass 1: V — amplitude + baseline + amp_skew
  local inter = {}
  for k, p in ipairs(pts) do
    local amp_mult = 1.0
    if S.amp_skew ~= 0 then
      local tn = math.max(0, math.min(1, (p.t - t_first) / t_range))
      if S.amp_skew >= 0 then
        amp_mult = (1 - S.amp_skew) + S.amp_skew * tn
      else
        amp_mult = (1 + S.amp_skew) - S.amp_skew * (1 - tn)
      end
    end
    inter[k] = math.max(0, math.min(1,
      0.5 + (p.vn - 0.5) * S.amplitude * amp_mult + shift))
  end

  -- Dynamic range for tilt
  local v_min, v_max = math.huge, -math.huge
  for _, nv in ipairs(inter) do
    if nv < v_min then v_min = nv end
    if nv > v_max then v_max = nv end
  end
  local mid_v = (v_min + v_max) * 0.5

  -- Pass 2: tilt
  local vtilt = {}
  for k, p in ipairs(pts) do
    local nv = inter[k]
    if S.tilt ~= 0 then
      local tn = math.max(0, math.min(1, (p.t - t_first) / t_range))
      local tc = S.tilt_curve
      local tw = tn * (tc + 1) * 0.5 + (1 - tn) * (1 - tc) * 0.5
      if S.tilt > 0 and nv < mid_v then
        local target = v_min + tw * (v_max - v_min)
        nv = math.max(0, math.min(1, nv + (target - nv) * S.tilt))
      elseif S.tilt < 0 and nv > mid_v then
        local target = v_max + tw * (v_min - v_max)
        nv = math.max(0, math.min(1, nv + (target - nv) * (-S.tilt)))
      end
    end
    vtilt[k] = nv
  end

  -- H pipeline: h_compress → freq_skew → swing
  local t0 = {}
  for k, p in ipairs(pts) do t0[k] = p.t end

  -- Stage 1: h_compress — clamped to prevent full point collapse
  local min_total_range = #pts * 0.0001
  local max_allowed_compress = 1.0 - (min_total_range / t_range)
  local compress = math.min(math.max(0, max_allowed_compress), S.h_compress)

  local t1 = {}
  for k, t in ipairs(t0) do
    if compress ~= 0 then
      local anchor = t_first + S.h_anchor * t_range
      t1[k] = anchor + (t - anchor) * (1 - compress)
    else
      t1[k] = t
    end
  end

  -- Stage 2: freq_skew (chained from t1)
  -- Symmetric formula: both ±skew produce equal visual force.
  -- Positive skew: compress right side toward pivot, expand left away.
  -- Negative skew: compress left side toward pivot, expand right away.
  -- Using d^pwr (compress) and 1-(1-d)^pwr (expand) — mirror images.
  local t2 = {}
  for k, t in ipairs(t1) do
    if S.freq_skew ~= 0 then
      local rel = math.max(0, math.min(1, (t - t_first) / t_range))
      local c   = math.max(0.001, math.min(0.999, S.skew_pivot))
      local pwr = 1.0 + math.abs(S.freq_skew) * 2.5   -- [1, 3.5]
      local skw
      if rel <= c then
        local d = rel / c   -- [0,1] from left edge to pivot
        if S.freq_skew >= 0 then
          d = 1.0 - (1.0 - d) ^ pwr   -- expand left: push away from pivot leftward
        else
          d = d ^ pwr                  -- compress left: push toward pivot
        end
        skw = d * c
      else
        local d = (rel - c) / (1.0 - c)   -- [0,1] from pivot to right edge
        if S.freq_skew >= 0 then
          d = d ^ pwr                      -- compress right: push toward pivot
        else
          d = 1.0 - (1.0 - d) ^ pwr       -- expand right: push away from pivot
        end
        skw = c + d * (1.0 - c)
      end
      t2[k] = t_first + skw * t_range
    else
      t2[k] = t
    end
  end

  -- Stage 3: swing (chained from t2)
  local n  = #pts
  local tf = {}
  for k = 1, n do
    local t = t2[k]
    if S.swing ~= 0 and k > 1 and k < n then
      local even = (k % 2 == 0)
      local aff  = (S.swing_odd and even) or (not S.swing_odd and not even)
      if aff then
        -- Clamp to 0.999 so the affected point never reaches its neighbor's
        -- exact position, which would cause point collapse and sort-order inversion.
        if S.swing > 0 then
          t = t + (t2[k+1] - t) * math.min(S.swing, 0.999)
        else
          t = t + (t - t2[k-1]) * math.max(S.swing, -0.999)
        end
      end
    end
    -- Clamp to original range
    tf[k] = math.max(t_first, math.min(t_last, t))
  end

  local result = {}
  for k = 1, n do
    result[k] = { t = tf[k], vn = vtilt[k] }
  end
  return result
end

return M
