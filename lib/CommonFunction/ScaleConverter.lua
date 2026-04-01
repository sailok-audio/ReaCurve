-- ============================================================
--   ScaleConverter.lua
--   Linear [0,1] ↔ audio scale conversion (volume dB, pitch semitones, tempo BPM).
--   Pure math — no REAPER API calls except constructors that read preferences.
--
--   Shared API for all converter types:
--     :toNative(linear)            → amplitude (vol) | semitones (pitch) | BPM (tempo)
--     :fromNative(native)          → linear [0,1]
--     :toEnvelope(linear, mode)    → REAPER envelope value
--     :fromEnvelope(env_val, mode) → linear [0,1]
-- ============================================================

ScaleConverter = {}
ScaleConverter.__index = ScaleConverter

-- ── Volume calibration data ───────────────────────────────────
-- Piecewise curve calibrated against REAPER measurements:
--   raw=3 ( 0dB): 0.25→-40dB  0.50→-20dB  0.75→ -9dB
--   raw=2 (+6dB): 0.25→-35dB  0.50→-16dB  0.75→-3.5dB
--   raw=6(+12dB): 0.25→-30dB  0.50→-11dB  0.75→+2.2dB
--   raw=7(+24dB): 0.25→-23dB  0.50→-2.2dB 0.75→+12dB
local VOL_PARAMS = {
  [3] = { split=1.0000, n=3.3219, max_db= 0 },
  [2] = { split=0.8421, n=3.3180, max_db= 6 },
  [6] = { split=0.7083, n=3.3164, max_db=12 },
  [7] = { split=0.5387, n=3.4490, max_db=24 },
}
local VOL_DB_TO_RAW = { [0]=3, [6]=2, [12]=6, [24]=7 }

-- ── Constructors ─────────────────────────────────────────────

-- Volume — reads range from REAPER preferences automatically.
function ScaleConverter.newVolume()
  local raw = 7
  if reaper.SNM_GetIntConfigVar then
    raw = reaper.SNM_GetIntConfigVar("volenvrange", 0)
  end
  return ScaleConverter.newVolumeFromRaw(raw)
end

-- Volume — from explicit raw config value (2, 3, 6, or 7).
function ScaleConverter.newVolumeFromRaw(raw_cfg)
  local p   = VOL_PARAMS[raw_cfg] or VOL_PARAMS[7]
  local self = setmetatable({}, ScaleConverter)
  self.type     = "volume"
  self.raw_cfg  = raw_cfg
  self.max_db   = p.max_db
  self.max_gain = 10.0 ^ (p.max_db / 20.0)
  self.split    = p.split
  self.n        = p.n
  return self
end

-- Volume — from max_db (0, 6, 12, or 24).
function ScaleConverter.newVolumeFromDb(max_db)
  local raw = VOL_DB_TO_RAW[max_db]
  assert(raw, "newVolumeFromDb: max_db must be 0, 6, 12 or 24")
  return ScaleConverter.newVolumeFromRaw(raw)
end

-- Pitch — reads range from REAPER preferences automatically.
function ScaleConverter.newPitch()
  local range = 12
  if reaper.SNM_GetIntConfigVar then
    local raw = reaper.SNM_GetIntConfigVar("pitchenvrange", 0)
    local val = raw & 0xFF
    if val > 0 then range = val end
  end
  return ScaleConverter.newPitchFromRange(range)
end

-- Pitch — from explicit semitone range (e.g. 12, 24, 48).
function ScaleConverter.newPitchFromRange(range)
  assert(range > 0, "newPitchFromRange: range must be > 0")
  local self = setmetatable({}, ScaleConverter)
  self.type  = "pitch"
  self.range = range
  return self
end

-- Tempo — reads BPM range from REAPER preferences automatically.
function ScaleConverter.newTempo()
  local t_min, t_max = 60, 180
  if reaper.SNM_GetIntConfigVar then
    local mn = reaper.SNM_GetIntConfigVar("tempoenvmin", -1)
    local mx = reaper.SNM_GetIntConfigVar("tempoenvmax", -1)
    if mn > 0 then t_min = mn end
    if mx > 0 then t_max = mx end
  end
  return ScaleConverter.newTempoFromRange(t_min, t_max)
end

-- Tempo — from explicit BPM bounds.
function ScaleConverter.newTempoFromRange(t_min, t_max)
  assert(t_min < t_max, "newTempoFromRange: t_min must be < t_max")
  local self = setmetatable({}, ScaleConverter)
  self.type  = "tempo"
  self.t_min = t_min
  self.t_max = t_max
  return self
end

-- ── Shared API ───────────────────────────────────────────────

-- linear [0,1] → native value (amplitude | semitones | BPM).
function ScaleConverter:toNative(v)
  if self.type == "volume" then return self:_linearToAmplitude(v)
  elseif self.type == "pitch" then return self:_linearToPitch(v)
  elseif self.type == "tempo" then return self:_linearToBpm(v) end
end

-- native value → linear [0,1].
function ScaleConverter:fromNative(native)
  if self.type == "volume" then return self:_amplitudeToLinear(native)
  elseif self.type == "pitch" then return self:_pitchToLinear(native)
  elseif self.type == "tempo" then return self:_bpmToLinear(native) end
end

-- linear [0,1] → REAPER envelope value.
function ScaleConverter:toEnvelope(linear_val, scaling_mode)
  return reaper.ScaleToEnvelopeMode(scaling_mode, self:toNative(linear_val))
end

-- REAPER envelope value → linear [0,1].
function ScaleConverter:fromEnvelope(env_val, scaling_mode)
  return self:fromNative(reaper.ScaleFromEnvelopeMode(scaling_mode, env_val))
end

-- ── Volume internals ─────────────────────────────────────────

function ScaleConverter:_linearToAmplitude(v)
  if v <= 0 then return 0.0 end
  if v >= 1 then return self.max_gain end
  if v <= self.split then
    return (v / self.split) ^ self.n
  else
    local db = (v - self.split) / (1.0 - self.split) * self.max_db
    return 10.0 ^ (db / 20.0)
  end
end

function ScaleConverter:_amplitudeToLinear(amp)
  if amp <= 0 then return 0.0 end
  if amp >= self.max_gain then return 1.0 end
  if amp <= 1.0 then
    return self.split * (amp ^ (1.0 / self.n))
  else
    local db = math.log(amp) / math.log(10) * 20.0
    return self.split + (1.0 - self.split) * db / self.max_db
  end
end

-- ── Pitch internals ──────────────────────────────────────────

function ScaleConverter:_linearToPitch(v)
  v = math.max(0.0, math.min(1.0, v))
  return (v * 2.0 - 1.0) * self.range
end

function ScaleConverter:_pitchToLinear(semitones)
  semitones = math.max(-self.range, math.min(self.range, semitones))
  return (semitones / self.range + 1.0) / 2.0
end

-- ── Tempo internals ──────────────────────────────────────────

function ScaleConverter:_linearToBpm(v)
  v = math.max(0.0, math.min(1.0, v))
  return self.t_min + v * (self.t_max - self.t_min)
end

function ScaleConverter:_bpmToLinear(bpm)
  bpm = math.max(self.t_min, math.min(self.t_max, bpm))
  return (bpm - self.t_min) / (self.t_max - self.t_min)
end

-- ── Debug ────────────────────────────────────────────────────

function ScaleConverter:info()
  if self.type == "volume" then
    return string.format(
      "ScaleConverter [volume] raw=%d  max_db=%d  split=%.4f  n=%.4f",
      self.raw_cfg, self.max_db, self.split, self.n)
  elseif self.type == "pitch" then
    return string.format("ScaleConverter [pitch]  range=±%d semitones", self.range)
  elseif self.type == "tempo" then
    return string.format("ScaleConverter [tempo]  range=%d-%d BPM", self.t_min, self.t_max)
  end
end

return ScaleConverter
