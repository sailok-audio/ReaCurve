-- ============================================================
--   SCULPTConfig.lua
--   Amplitude ranges constant and window dimension defaults.
-- ============================================================

local M = {}

-- ── Amplitude ranges ──────────────────────────────────────────

M.RANGES = {
  { lo=0.0,  hi=1.0,  label="-100/+100",   desc="-100% → +100%" },
  { lo=0.5,  hi=1.0,  label="   0/+100",  desc="  0%  → +100%" },
  { lo=0.0,  hi=0.5,  label="-100/  0 ",  desc="-100% →  0%"   },
  { lo=0.25, hi=0.75, label=" -50/+50 ", desc=" -50% → +50%"  },
}

-- ── Window dimensions ─────────────────────────────────────────

M.WIN_W     = 420
M.WIN_H     = 885
M.WIN_MIN_W = 320
M.WIN_MIN_H = 500
M.WIN_MAX_W = 900
M.WIN_MAX_H = 1800

return M
