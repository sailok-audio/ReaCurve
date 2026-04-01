-- ============================================================
--   CommonFunction/EnvConvert.lua
--   Linear <-> native envelope value conversion for REAPER.
--   Shared by: RANDWrite, LFOWrite, SCULPTWrite.
-- ============================================================

local M = {}

-- Converts a normalized linear value [0,1] to a native envelope value.
-- conv  : ScaleConverter (or nil for envelopes without a specific converter)
-- lo,hi : envelope range (resolved MINVAL/MAXVAL)
-- mode  : scaling mode (0=linear, 1=fader)
function M.toEnvValue(v, conv, lo, hi, mode)
  if conv then
    if conv.type == "volume" then return conv:toEnvelope(v, mode)
    else                          return conv:toNative(v) end
  end
  local v_fader = (mode == 1) and v or (lo + v * (hi - lo))
  return reaper.ScaleToEnvelopeMode(mode, v_fader)
end

-- Converts a native envelope value to a normalized linear value [0,1].
function M.fromEnvValue(v_raw, conv, lo, hi, mode)
  if conv then
    if conv.type == "volume" then return conv:fromEnvelope(v_raw, mode)
    else                          return conv:fromNative(v_raw) end
  end
  local vf    = reaper.ScaleFromEnvelopeMode(mode, v_raw)
  if mode == 1 then return vf end
  local range = hi - lo
  if math.abs(range) < 1e-9 then return 0.5 end
  return (vf - lo) / range
end

return M
