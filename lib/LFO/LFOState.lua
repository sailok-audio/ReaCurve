-- ============================================================
--   LFOState.lua
-- ============================================================
local M = {}

M.sides          = 4
M.phase          = 0.0
M.warp           = 0.0
M.amp            = 1.0     -- display/write amplitude scale [0,1]
M.offset         = 0.0     -- display/write DC offset [-1,1]
M.cycles         = 4
M.cycle_mode     = "fixed" -- "fixed" | "grid"

M.curve_mode     = 0
M.curve_amt      = 0.0

M.segment_shape  = 0
M.bezier_tension = 0.0

M.quantize       = 0
M.align          = 0.0
M.path_slide     = 0.0

M.amp_range      = 1       -- index into LFOConfig.AMP_RANGES
M.precision      = 6            -- sub-samples per segment (2=few pts, 16=many)

-- Fixed display constants
M.preview_cycles = 2
M.radar_range    = 2.0

M.v_offsets = {}
M.drag      = { active=false, idx=-1, last_mx=0, last_my=0 }

function M.resetOffsets()
  M.v_offsets = {}
end

return M
