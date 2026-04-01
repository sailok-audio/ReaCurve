-- ============================================================
--   RANDState.lua
--   Shared mutable state for the Random Generator.
--   Status messages live in Logger, not here.
-- ============================================================

local M = {}

-- ── Generation parameters ────────────────────────────────────
M.seed        = os.time()   -- main generation seed (positions + amplitudes)
M.shape_seed  = os.time()   -- separate seed for "Random" shape mode
M.gen_mode    = "free"      -- "free" | "grid"
M.num_points  = 8           -- number of points (free mode)
M.pts_per_div = 2           -- points per grid division (grid mode)
M.shape       = 0           -- shape id 0-5 = fixed shape, 6 = random per point
M.tension     = 0.0         -- bezier tension [-1,1]; active only when shape==5 or random picks bezier
M.amp_range   = 1           -- index into GeneratorConfig.AMP_RANGES (1-based)
M.amp_free    = true        -- true = free amplitude, false = quantized
M.quant_steps = 4           -- quantization levels (visible but inactive when amp_free=true)

-- ── Preview cache ─────────────────────────────────────────────
M.preview_pts   = {}        -- dense [{tn, v}] for display (256 samples)
M.gen_pts       = {}        -- control points [{tn, v, shape, tension}] from last generation
M.preview_dirty = true      -- forces regeneration on next frame

-- ── Helpers ───────────────────────────────────────────────────

-- Picks a new main seed (positions + amplitudes) and marks the preview dirty.
-- shape_seed is intentionally NOT touched here: it is controlled exclusively
-- by the RND shape button so the two seeds are fully independent.
function M.newSeed()
  M.seed          = math.floor(math.random() * 2147483647)
  M.preview_dirty = true
end

-- Re-rolls the shape seed only (called by the RND button).
function M.newShapeSeed()
  M.shape_seed    = math.floor(math.random() * 2147483647)
  M.preview_dirty = true
end

-- Marks the preview as needing regeneration.
function M.invalidatePreview()
  M.preview_dirty = true
end

return M