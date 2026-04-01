-- ============================================================
--   LFOConfig.lua
-- ============================================================
local M = {}

M.WIN_W     = 440
M.WIN_H     = 972
M.WIN_MIN_W = 340
M.WIN_MIN_H = 500
M.WIN_MAX_W = 900
M.WIN_MAX_H = 1500

M.RADAR_SIZE = 140
M.PREVIEW_H  = 100

M.SHAPES = {
  { id=0, name="Linear"     },
  { id=1, name="Square"     },
  { id=2, name="Smooth"     },
  { id=3, name="Fast Start" },
  { id=4, name="Fast End"   },
  { id=5, name="Bezier"     },
}

-- 0=Off,1=Sinus,2=Alternate,3=Wave,4=Wfold,5=Glitch
M.CURVE_MODES = { "Off", "Sinus", "Alt", "Wave", "Wfold", "Glitch" }

M.CYCLES_MIN = 1
M.CYCLES_MAX = 32
M.SIDES_MIN  = 2
M.SIDES_MAX  = 16

-- lo/hi in [0,1]: 0.0=-100%, 0.5=0%, 1.0=+100%
M.AMP_RANGES = {
  { lo=0.0,  hi=1.0,  label="-100/+100" },
  { lo=0.25, hi=0.75, label=" -50/+50 " },
  { lo=0.0,  hi=0.5,  label="-100/  0 " },
  { lo=0.5,  hi=1.0,  label="   0/+100" },
}

-- Point reduction precision presets (morpher-style)
-- threshold_pct: max error as % of dynamic range
-- density: dense sample count multiplier for shapeFit
M.PRECISION_PRESETS = {
  { name="Ultra-Precise",  threshold_pct=0.10, density=400 },
  { name="High Fidelity",  threshold_pct=0.30, density=300 },
  { name="Default",        threshold_pct=0.50, density=200 },
  { name="Compressed",     threshold_pct=1.50, density=150 },
  { name="Aggressive",     threshold_pct=3.00, density=80  },
}

return M