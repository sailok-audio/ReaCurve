-- ============================================================
--   CommonFunction/GridUtils.lua
--   REAPER temporal grid calculations (divisions, snap).
--   Shared by: RANDWrite, LFOWrite.
-- ============================================================

local M = {}

-- Returns the list of absolute times (in seconds) of grid lines
-- within the interval [ts_s, ts_e]. Handles tempo changes.
function M.getGridTimes(ts_s, ts_e)
  local _, division = reaper.GetSetProjectGrid(0, false)
  division = (division and division > 0) and division or 0.25
  -- GetSetProjectGrid returns fractions of a whole note (0.25 = quarter note)
  -- TimeMap_timeToQN returns quarter notes → multiply by 4
  local division_qn = division * 4
  local ts_qn       = reaper.TimeMap_timeToQN(ts_s)
  local te_qn       = reaper.TimeMap_timeToQN(ts_e)
  local first_idx   = math.ceil (ts_qn / division_qn - 1e-6)
  local last_idx    = math.floor(te_qn / division_qn + 1e-6)

  local times = {}
  for i = first_idx, last_idx do
    local t = reaper.TimeMap_QNToTime(i * division_qn)
    if t >= ts_s - 1e-4 and t <= ts_e + 1e-4 then
      if #times == 0 or (t - times[#times]) > 1e-4 then
        times[#times+1] = t
      end
    end
  end
  return times
end

-- Converts absolute times to normalized divisions [{lo, hi}] within [ts_s, ts_e].
function M.getGridDivisions(ts_s, ts_e)
  local ts_len = ts_e - ts_s
  if ts_len < 1e-6 then return {{ lo=0.0, hi=1.0 }} end

  local times = M.getGridTimes(ts_s, ts_e)
  if #times < 2 then return {{ lo=0.0, hi=1.0 }} end

  local divs = {}
  for i = 1, #times - 1 do
    divs[#divs+1] = {
      lo = (times[i]   - ts_s) / ts_len,
      hi = (times[i+1] - ts_s) / ts_len,
    }
  end
  divs[1].lo     = 0.0
  divs[#divs].hi = 1.0
  return divs
end

-- Rounds an absolute time to the nearest grid line.
function M.snapToGrid(t)
  local _, division = reaper.GetSetProjectGrid(0, false)
  division = (division and division > 0) and division or 0.25
  local division_qn = division * 4
  local t_qn        = reaper.TimeMap_timeToQN(t)
  local idx         = math.floor(t_qn / division_qn + 0.5)
  return reaper.TimeMap_QNToTime(idx * division_qn)
end

return M
