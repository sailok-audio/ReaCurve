-- ============================================================
--   CommonFunction/Anim.lua
--   Shared UI animation helpers.
--
--   Exported functions:
--     M.warnAlpha(start_t, freq_hz, alpha_hi, alpha_lo)
--     M.newSectionFader(fade_dur) → sectionAlpha(key, condition)
-- ============================================================

local M = {}

local BLINK_DURATION = 4.0

-- Oscillating alpha for warnings.
-- start_t  : reaper.time_precise() at the moment the warning starts (nil → alpha_hi directly)
-- freq_hz  : blink frequency (typically 1.2)
-- alpha_hi : target alpha once the animation is done
-- alpha_lo : minimum alpha during blinking
function M.warnAlpha(start_t, freq_hz, alpha_hi, alpha_lo)
  if not start_t then return alpha_hi end
  local elapsed = reaper.time_precise() - start_t
  if elapsed >= BLINK_DURATION then return alpha_hi end
  local fade = 1.0 - (elapsed / BLINK_DURATION)
  local p    = (math.sin(elapsed * math.pi * 2 * freq_hz) + 1) * 0.5
  return alpha_hi - (alpha_hi - alpha_lo) * (1 - p) * fade
end

-- Creates an isolated sectionAlpha instance with its own state.
-- fade_dur : fade duration (seconds, default 0.25)
-- Returns : function(key, condition) → alpha [0,1], should_render (bool)
--
-- Usage:
--   local sectionAlpha = Anim.newSectionFader(0.25)
--   -- then in draw:
--   local a, vis = sectionAlpha("my_section", someCondition)
function M.newSectionFader(fade_dur)
  fade_dur = fade_dur or 0.25
  local _sec_fade = {}

  local function ease(t) return t * t * (3 - 2 * t) end  -- smoothstep

  return function(key, condition)
    local fs = _sec_fade[key]
    if not fs then
      local a = condition and 1.0 or 0.0
      _sec_fade[key] = { alpha=a, cond=condition, t_start=nil, from=a, to=a }
      return a, a > 0.001
    end
    if condition ~= fs.cond then
      fs.cond    = condition
      fs.t_start = reaper.time_precise()
      fs.from    = fs.alpha
      fs.to      = condition and 1.0 or 0.0
    end
    if fs.t_start then
      local elapsed = reaper.time_precise() - fs.t_start
      local t       = math.min(1.0, elapsed / fade_dur)
      fs.alpha      = fs.from + (fs.to - fs.from) * ease(t)
      if t >= 1.0 then fs.alpha = fs.to ; fs.t_start = nil end
    end
    return fs.alpha, fs.alpha > 0.001
  end
end

-- Smoothstep ease in/out [0,1] → [0,1].
function M.easeInOut(t) return t * t * (3 - 2 * t) end

return M
