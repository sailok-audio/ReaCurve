-- ============================================================
--   LFOPresets.lua  — file-based presets in LFOPresets/
--   One .lua file per preset, stored in a "LFOPresets/" folder
--   located next to this script file (stable across projects).
-- ============================================================
local M = {}
local S = require("LFOState")

local _preset_dir = nil

function M.init()
  -- Resolve the directory where THIS script lives
  local script_path = ""
  if reaper.get_action_context then
    local _,sp = reaper.get_action_context()
    script_path = sp:match("^(.+[/\\])") or ""
  end
  if script_path == "" then
    -- Ultimate fallback: REAPER resource path
    script_path = reaper.GetResourcePath() .. "/"
  end

  _preset_dir = script_path .. "LFOPresets/"

  if reaper.RecursiveCreateDirectory then
    reaper.RecursiveCreateDirectory(_preset_dir, 0)
  end
  return _preset_dir
end

function M.getDir() return _preset_dir end

local function presetPath(name)
  return _preset_dir .. name .. ".lua"
end

local function sanitizeName(name)
  local parts = {}
  for seg in (name .. "/"):gmatch("([^/]*)/") do
    seg = seg:gsub('[\\:*?"<>|]', "_"):gsub("^%s+", ""):gsub("%s+$", "")
    if seg ~= "" then parts[#parts+1] = seg end
  end
  return table.concat(parts, "/")
end

local function serialize()
  local t = {
    "return {",
    ("  sides=%d,"):format(S.sides),
    ("  phase=%.6f,"):format(S.phase),
    ("  warp=%.6f,"):format(S.warp),
    ("  amp=%.6f,"):format(S.amp),
    ("  offset=%.6f,"):format(S.offset),
    ("  cycles=%d,"):format(S.cycles),
    ("  cycle_mode='%s',"):format(S.cycle_mode),
    ("  curve_mode=%d,"):format(S.curve_mode),
    ("  curve_amt=%.6f,"):format(S.curve_amt),
    ("  segment_shape=%d,"):format(S.segment_shape),
    ("  bezier_tension=%.6f,"):format(S.bezier_tension),
    ("  quantize=%d,"):format(S.quantize),
    ("  align=%.6f,"):format(S.align),
    ("  path_slide=%.6f,"):format(S.path_slide),
    ("  amp_range=%d,"):format(S.amp_range),
    "  v_offsets={",
  }
  for i = 0, S.sides - 1 do
    local off = S.v_offsets[i]
    if off then
      t[#t+1] = ("    [%d]={%.6f,%.6f},"):format(i, off[1], off[2])
    end
  end
  t[#t+1] = "  },"
  t[#t+1] = "}"
  return table.concat(t, "\n")
end

local function applyData(d)
  if type(d) ~= "table" then return false end
  S.sides          = d.sides          or S.sides
  S.phase          = d.phase          or S.phase
  S.warp           = d.warp           or S.warp
  S.amp            = d.amp            or S.amp
  S.offset         = d.offset         or S.offset
  S.cycles         = d.cycles         or S.cycles
  S.cycle_mode     = d.cycle_mode     or S.cycle_mode
  S.curve_mode     = d.curve_mode     or S.curve_mode
  S.curve_amt      = d.curve_amt      or S.curve_amt
  S.segment_shape  = d.segment_shape  or S.segment_shape
  S.bezier_tension = d.bezier_tension or S.bezier_tension
  S.quantize       = d.quantize       or S.quantize
  S.align          = d.align          or S.align
  S.path_slide     = d.path_slide     or S.path_slide
  S.amp_range      = d.amp_range      or S.amp_range
  S.v_offsets = {}
  if type(d.v_offsets) == "table" then
    for k, v in pairs(d.v_offsets) do
      if type(v) == "table" then
        S.v_offsets[k] = { v[1] or 0, v[2] or 0 }
      end
    end
  end
  return true
end

-- Returns true if a preset file with this name exists
function M.exists(name)
  if not _preset_dir or name == "" then return false end
  local f = io.open(presetPath(name), "r")
  if f then f:close(); return true end
  return false
end

-- Save; overwrites if overwrite=true, otherwise returns nil,"exists" if collision
function M.save(name, overwrite)
  if not _preset_dir then return nil, "not initialized" end
  name = sanitizeName(name)
  if name == "" then return nil, "empty name" end
  if not overwrite and M.exists(name) then return nil, "exists" end
  local path = presetPath(name)
  local dir = path:match("^(.+[/\\])")
  if dir and reaper.RecursiveCreateDirectory then
    reaper.RecursiveCreateDirectory(dir, 0)
  end
  local f = io.open(path, "w")
  if not f then return nil, "cannot write to: " .. path end
  f:write(serialize()); f:close()
  return name
end

function M.load(name)
  if not _preset_dir then return false, "not initialized" end
  local fn, err = loadfile(presetPath(name))
  if not fn then return false, err end
  local ok, data = pcall(fn)
  if not ok then return false, tostring(data) end
  return applyData(data)
end

function M.delete(name)
  if not _preset_dir or name == "" then return false end
  os.remove(presetPath(name))
  return true
end

function M.list()
  if not _preset_dir then return {} end
  local names = {}
  if reaper.EnumerateFiles then
    local function scan(dir, prefix)
      local i = 0
      while true do
        local f = reaper.EnumerateFiles(dir, i)
        if not f then break end
        if f:match("%.lua$") then names[#names+1] = prefix .. f:sub(1, -5) end
        i = i + 1
      end
      if reaper.EnumerateSubdirectories then
        local j = 0
        while true do
          local d = reaper.EnumerateSubdirectories(dir, j)
          if not d then break end
          scan(dir .. d .. "/", prefix .. d .. "/")
          j = j + 1
        end
      end
    end
    scan(_preset_dir, "")
  end
  table.sort(names, function(a, b)
    local af = a:match("^.+/")
    local bf = b:match("^.+/")
    if not af and not bf then return a < b end
    if af and not bf then return true end   -- folders first
    if not af and bf then return false end
    return a < b
  end)
  return names
end

-- Reset state to factory defaults
function M.initDefaults()
  local S = require("LFOState")
  S.sides = 4; S.phase = 0; S.warp = 0; S.amp = 1; S.offset = 0
  S.cycles = 4; S.cycle_mode = "fixed"; S.curve_mode = 0; S.curve_amt = 0
  S.segment_shape = 0; S.bezier_tension = 0; S.quantize = 0
  S.align = 0; S.path_slide = 0; S.amp_range = 1; S.v_offsets = {}
end

return M