-- ============================================================
--   RANDConfig.lua
--   Static configuration for the Random Generator tool.
--   No REAPER API calls.
-- ============================================================

local M = {}

-- ── Window ───────────────────────────────────────────────────
M.WIN_W     = 300
M.WIN_H     = 872
M.WIN_MIN_W = 320
M.WIN_MIN_H = 500
M.WIN_MAX_W = 900
M.WIN_MAX_H = 1400

-- ── Layout ───────────────────────────────────────────────────
M.GRAPH_HEIGHT = 160   -- preview graph height (px)

-- ── Shape definitions ────────────────────────────────────────
-- id matches REAPER envelope point shape integer.
-- id=6 is a meta-shape "Random": shape is picked per point at generation time.
M.SHAPES = {
  { id=0, name="Linear"   },
  { id=1, name="Square"   },
  { id=2, name="Slow S/E" },
  { id=3, name="Fast +"   },
  { id=4, name="Fast -"   },
  { id=5, name="Bezier"   },
  { id=6, name="Random"   },
}

-- Shapes available when "Random" is active (excludes the meta-shape itself).
M.RANDOM_SHAPE_POOL = { 0, 1, 2, 3, 4, 5 }

-- ── Amplitude ranges ─────────────────────────────────────────
-- lo / hi are normalized [0,1]: 0.5 = centre (0%), 0.0 = -100%, 1.0 = +100%.
M.AMP_RANGES = {
  { lo=0.0,  hi=1.0,  label="-100 / +100" },
  { lo=0.25, hi=0.75, label=" -50 /  +50" },
  { lo=0.0,  hi=0.5,  label="-100 /    0" },
  { lo=0.5,  hi=1.0,  label="   0 / +100" },
}

-- Converts a normalized [0,1] value to a bipolar percentage string.
-- 0.0 = -100%,  0.5 = 0%,  1.0 = +100%
function M.normToPct(v)
  return math.floor((v * 2 - 1) * 100 + 0.5)
end

return M
