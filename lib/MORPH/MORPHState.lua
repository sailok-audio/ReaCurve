-- ============================================================
--   MORPHState.lua
--   Shared mutable state singleton.
--   Import with: local State = require("MORPHState")
--   Status/error messages live in Logger, not here.
-- ============================================================

local M = {}

-- Source slots.
-- ai_obj  : { track_idx, env_idx, ai_idx, pos, len, label, tname, ename,
--             frozen_samples, frozen_norm, frozen_diag, frozen_vmin, frozen_vmax }
-- sel_obj : { pts, label, mode, vmin, vmax, len, t0_abs, frozen_samples, ... }
M.ai1, M.ai2     = nil, nil
M.sel1, M.sel2   = nil, nil

-- Slot type: nil = empty | "ai" = automation item | "sel" = point selection
M.slot1_type, M.slot2_type = nil, nil

-- Morph parameter [0, 1]. 0 = 100% source 1, 1 = 100% source 2.
M.morph = 0.5

-- Capture workflow state. 0 = idle, 1 = awaiting slot 1, 2 = awaiting slot 2.
M.capture_mode = 0

-- Envelope display cache (invalidated when ai1/ai2 change).
M.norm1, M.norm2         = {}, {}
M.vmin1, M.vmax1         = 0, 1
M.vmin2, M.vmax2         = 0, 1
M.diag1, M.diag2         = "", ""
M.prev_key1, M.prev_key2 = nil, nil

-- Preview cache (invalidated on morph or source change).
M.prev_cache_key     = ""
M.prev_samples       = {}   -- morphed curve [{tn, v}] — updated every frame
M.prev_fitted        = {}   -- shapeFit result [{tn, v, shape}] — updated on drag release
M.prev_fitted_stable = {}   -- stable snapshot used for dot display

-- Drag interaction state.
M.slider_dragging = false   -- true while the morph slider is being dragged
M.bar_dragging    = false   -- true while the morph bar inside the graph is dragged

-- Metrics from the last generate call (for diagnostics).
M.last_stats = {
  pts_in      = 0,
  pts_out     = 0,
  time_ms     = 0,
  max_err_pct = 0,
  ratio       = 0,
}
M.last_fitted = {}

-- ── Helpers ──────────────────────────────────────────────────

-- Returns true when slot n has a captured source.
function M.slotReady(n)
  if n == 1 then
    return (M.slot1_type == "ai"  and M.ai1  ~= nil)
        or (M.slot1_type == "sel" and M.sel1 ~= nil)
  else
    return (M.slot2_type == "ai"  and M.ai2  ~= nil)
        or (M.slot2_type == "sel" and M.sel2 ~= nil)
  end
end

-- Returns the duration (seconds) of slot n, or 0 if empty.
function M.getSlotLen(n)
  if n == 1 then
    if M.slot1_type == "ai"  and M.ai1  then return M.ai1.len  end
    if M.slot1_type == "sel" and M.sel1 then return M.sel1.len end
  else
    if M.slot2_type == "ai"  and M.ai2  then return M.ai2.len  end
    if M.slot2_type == "sel" and M.sel2 then return M.sel2.len end
  end
  return 0
end

-- Clears slot n and invalidates the preview cache.
function M.clearSlot(n)
  if n == 1 then
    M.ai1 = nil ; M.sel1 = nil
    M.norm1 = {} ; M.prev_key1 = nil
    M.vmin1, M.vmax1 = 0, 1 ; M.diag1 = ""
    M.slot1_type = nil
  else
    M.ai2 = nil ; M.sel2 = nil
    M.norm2 = {} ; M.prev_key2 = nil
    M.vmin2, M.vmax2 = 0, 1 ; M.diag2 = ""
    M.slot2_type = nil
  end
  M.invalidatePreview()
end

-- Forces full preview recalculation on the next frame.
function M.invalidatePreview()
  M.prev_cache_key     = ""
  M.prev_samples       = {}
  M.prev_fitted        = {}
  M.prev_fitted_stable = {}
end

return M
