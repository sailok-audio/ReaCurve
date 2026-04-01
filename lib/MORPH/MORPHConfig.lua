-- ============================================================
--   MORPHConfig.lua
--   Editable parameters: layout, presets, algorithm tuning.
--   No REAPER API calls.
-- ============================================================

local M = {}

-- ── Window ───────────────────────────────────────────────────
M.WIN_W     = 700
M.WIN_H     = 736
M.WIN_MIN_W = 330
M.WIN_MIN_H = 500
M.WIN_MAX_W = 1200
M.WIN_MAX_H = 1400

-- ── Layout ───────────────────────────────────────────────────
M.GRAPH_HEIGHT = 200   -- main graph height (px)
M.MINI_H       = 60    -- source mini-graph height (px)

-- ── Point-reduction algorithm tuning ─────────────────────────
--   threshold_pct   : error tolerance as % of dynamic range
--   samples_per_sec : sample density for generation
--   max_samples     : absolute sample count ceiling
--   early_break_gap : gap before shapeFit early-exit
--   early_break_mult: multiplier for early-exit
M.TUNE = {
  threshold_pct    = 0.5,
  samples_per_sec  = 200,
  max_samples      = 2048,
  early_break_gap  = 40,
  early_break_mult = 10,
}

-- ── Max Samples selector steps ───────────────────────────────
M.MAX_SAMPLES_STEPS = { 512, 1024, 2048, 4096 }
M.max_samples_idx   = 3   -- default → 2048

-- ── Precision presets ────────────────────────────────────────
M.PRESETS = {
  { name = "Ultra-Precise",
    threshold_pct = 0.10, samples_per_sec = 400,
    early_break_gap = 80, early_break_mult = 20 },
  { name = "High Fidelity",
    threshold_pct = 0.30, samples_per_sec = 300,
    early_break_gap = 60, early_break_mult = 15 },
  { name = "Default",
    threshold_pct = 0.50, samples_per_sec = 200,
    early_break_gap = 40, early_break_mult = 10 },
  { name = "Compressed",
    threshold_pct = 1.50, samples_per_sec = 150,
    early_break_gap = 25, early_break_mult = 8  },
  { name = "Aggressive",
    threshold_pct = 3.00, samples_per_sec = 80,
    early_break_gap = 10, early_break_mult = 5  },
}
M.active_preset = 3   -- default → "Default"

-- Applies preset[idx] into TUNE.
function M.applyPreset(idx)
  local p = M.PRESETS[idx]
  if not p then return end
  M.active_preset         = idx
  M.TUNE.threshold_pct    = p.threshold_pct
  M.TUNE.samples_per_sec  = p.samples_per_sec
  M.TUNE.early_break_gap  = p.early_break_gap
  M.TUNE.early_break_mult = p.early_break_mult
  M.TUNE.max_samples      = M.MAX_SAMPLES_STEPS[M.max_samples_idx] or 2048
end

-- Applies MAX_SAMPLES_STEPS[idx] into TUNE.
function M.applyMaxSamples(idx)
  M.max_samples_idx  = math.max(1, math.min(#M.MAX_SAMPLES_STEPS, idx))
  M.TUNE.max_samples = M.MAX_SAMPLES_STEPS[M.max_samples_idx]
end

return M
