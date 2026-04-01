-- ============================================================
--   SCULPTState.lua
--   Shared mutable state for the Envelope Manipulator.
-- ============================================================

local M = {}

-- ── Shape ────────────────────────────────────────────────────
M.point_type = 0    -- 0=Linear 1=Square 2=Slow S/E 3=Fast+ 4=Fast- 5=Bezier
M.tension    = 0.0

-- ── Range for random operations (1-indexed) ─────────────────
M.range_type = 1    -- 1=Full, 2=Upper, 3=Lower, 4=Center

-- ── Options ──────────────────────────────────────────────────
M.rnd_edges  = false  -- randomize edge points too
M.swing_odd  = true   -- true=even idx (2,4,6…), false=odd idx (3,5,7…)

-- ── Live modifier sliders ────────────────────────────────────
-- Reset whenever the selection changes
M.baseline       = 0.0
M.amplitude      = 1.0
M.h_compress     = 0.0
M.h_anchor       = 0.0   -- anchor at left edge (0)
M.freq_skew      = 0.0
M.skew_pivot     = 0.0   -- pivot at left edge (0)
M.amp_skew       = 0.0
M.tilt           = 0.0
M.tilt_curve     = 1.0   -- initialized to 1 (logarithmic curve)
M.swing          = 0.0

-- ── Reference state ──────────────────────────────────────────
-- List of {env, ai_idx, pts, conv, lo, hi, mode}.
-- One entry per (env, ai_idx) captured context.
-- pts: [{idx, t, v, vn, shape, tension, orig_shape, orig_tension}]
M.ref_entries = {}    -- primary multi-track ref
M.ref_pts     = nil   -- legacy compat: {[ai_idx]=pts} for primary env only
M.ref_sel_id  = ""    -- change-detector key

-- Per-envelope converter (primary env, kept for single-env editPts)
M.ref_conv = nil
M.ref_lo   = 0
M.ref_hi   = 1
M.ref_mode = 0

-- ── Per-slider drag tracking (set by panels, read by logic) ──
M.drag_prev = {}   -- [id] = was_active_last_frame

-- ── Helpers ──────────────────────────────────────────────────

function M.resetModifiers()
  M.baseline   = 0.0
  M.amplitude  = 1.0
  M.h_compress = 0.0
  M.h_anchor   = 0.0   -- left edge
  M.freq_skew  = 0.0
  M.skew_pivot = 0.0   -- left edge
  M.amp_skew   = 0.0
  M.tilt       = 0.0
  M.tilt_curve = 1.0   -- logarithmic
  M.swing      = 0.0
end

function M.invalidatePreview()
  -- kept for API compatibility, no-op (no preview in this tool)
end

-- Returns true if any modifier is non-default
function M.hasModifiers()
  return M.baseline   ~= 0.0
      or M.amplitude  ~= 1.0
      or M.h_compress ~= 0.0
      or M.freq_skew  ~= 0.0
      or M.amp_skew   ~= 0.0
      or M.tilt       ~= 0.0
      or M.swing      ~= 0.0
end

return M
