-- ============================================================
--   LFOPanel.lua
-- ============================================================
local M = {}

local Theme    = require("Theme")
local Widgets  = require("Widgets")
local S        = require("LFOState")
local Cfg      = require("LFOConfig")
local Geo      = require("LFOGeometry")
local Generator = require("Generator")
local LFOWrite   = require("LFOWrite")
local LFOPresets = require("LFOPresets")
local Logger     = require("Logger")
local Anim       = require("Anim")
local Slider     = require("Slider")
local Toggle     = require("Toggle")

local T   = Theme
local PI  = math.pi
local PI2 = math.pi * 2

-- ── Preset state ──────────────────────────────────────────────
local _preset_list       = {}    -- cached list from disk
local _preset_sel        = ""    -- loaded preset name ("" = none)
local _preset_name_buf   = ""    -- save name input buffer
local _preset_list_dirty = true  -- needs refresh
local _ui_advanced = (reaper.GetExtState("LFOGenerator","ui_advanced")=="1")  -- persisted
local _preset_modified   = false -- true when state changed since last load/save
local _preset_overwrite_name = nil  -- pending overwrite confirmation
local _preset_snapshot    = ""  -- fingerprint of state when preset was loaded/saved
local _snapshot_ready     = false  -- true once snapshot has been captured this session
local _init_preset_sel    = ""  -- preset selected in init dropdown
local _unsaved_action     = nil -- pending action when unsaved: {type="load"|"init", arg=name}

-- ── Fade system for conditional sections ─────────────────────
local sectionAlpha = Anim.newSectionFader(0.35)
local function sectionEaseOut(t) return t * t * (3 - 2 * t) end  -- used by popup fade

-- Exposed for ReaCurve_LFO.lua (fades of entire sections)
function M.sectionAlpha(key, condition) return sectionAlpha(key, condition) end

-- Called at standalone startup to force a fresh snapshot
-- (Lua modules are cached between runs in REAPER)
function M.resetSnapshot()
  _snapshot_ready  = false
  _preset_snapshot = ""
end

-- ── Radar hover tooltip ───────────────────────────────────────
local RADAR_TIP_DELAY = 0.65   -- seconds before appearance
local RADAR_TIP_FADE  = 0.22   -- fade-in duration (smoothstep)
local _radar_tip = { idx = -1, t_start = nil }

-- Compute a simple string fingerprint of current LFOState for change detection
local function stateFingerprint()
  local vo = {}
  for i = 0, S.sides-1 do
    local off = S.v_offsets[i]
    if off then vo[#vo+1] = string.format("%d:%.3f,%.3f", i, off[1], off[2]) end
  end
  return string.format("%d|%.3f|%.3f|%.3f|%.3f|%d|%s|%d|%.3f|%d|%.3f|%d|%.3f|%.3f|%d|%d|%s",
    S.sides, S.phase, S.warp, S.amp, S.offset, S.cycles, S.cycle_mode,
    S.curve_mode, S.curve_amt, S.segment_shape, S.bezier_tension,
    S.quantize, S.align, S.path_slide, S.amp_range, S.precision_preset or 3,
    table.concat(vo, "|"))
end

local VI_ON_BG  = Widgets.VI_BG
local VI_ON_HOV = Widgets.VI_HOV
local VI_ON_BRD = Widgets.VI_BRD

-- ── Button hover timers (radar panel) ─────────────────────────
local _btn_hover_times = {}
local BTN_TIP_DELAY    = 0.30   -- seconds before tooltip appears

-- ── Popup cancel fade state ────────────────────────────────────
local _popup_closing  = false
local _popup_close_t  = nil
local POPUP_FADE_DUR  = 0.40

-- ══ Randomize ═════════════════════════════════════════════════
local function rnd(lo,hi) return lo+(hi-lo)*math.random() end
local function rndInt(lo,hi) return math.floor(lo+math.random()*(hi-lo+1)) end

local function randomizeAll()
  -- Always visible (Standard + Advanced)
  S.sides       = rndInt(Cfg.SIDES_MIN, Cfg.SIDES_MAX)
  S.phase       = rnd(0, 1)
  S.amp         = rnd(0.3, 1.0)
  S.offset      = rnd(-0.5, 0.5)
  -- Cycles and cycle_mode NOT modified (user config)
  -- Shape: all possible shapes including Bezier
  S.segment_shape = rndInt(0, #Cfg.SHAPES-1)
  if S.segment_shape == 5 then
    S.bezier_tension = rnd(-1, 1)
  else
    S.bezier_tension = 0
  end
  -- Curve mode + amount (Advanced only)
  if _ui_advanced then
    local n_modes = #Cfg.CURVE_MODES
    S.curve_mode = rndInt(0, n_modes-1)
    S.curve_amt  = rnd(-1, 1)
  end
  -- Radar points: random offsets
  S.v_offsets = {}
  for i=1, S.sides-1 do
    if math.random() > 0.3 then
      local vr = rnd(-0.8, 0.0)
      local vt = rnd(-0.4, 0.4)
      S.v_offsets[i] = {vr, vt}
      Geo.ClampOffsets(i)
    end
  end
  -- Advanced only
  if _ui_advanced then
    S.warp       = rnd(-0.6, 0.6)
    S.align      = rnd(0, 0.5)
    S.path_slide = rnd(0, 0.5)
  else
    S.warp  = 0
    S.align = 0
  end
  -- Quantize (always visible)
  S.quantize = math.random() > 0.7 and rndInt(2,8) or 0
end

local function randomizeRadar()
  S.v_offsets = {}
  for i=1, S.sides-1 do
    if math.random() > 0.25 then
      local vr = rnd(-0.8, 0.0)
      local vt = rnd(-0.4, 0.4)
      S.v_offsets[i] = {vr, vt}
      Geo.ClampOffsets(i)
    end
  end
  -- Always: phase + slide
  S.phase      = rnd(0, 1)
  S.path_slide = rnd(0, 1)
  -- Advanced only: warp + align
  if _ui_advanced then
    S.warp  = rnd(-0.6, 0.6)
    S.align = rnd(0, 0.5)
  end
end

-- Draw a dice icon centered in area bx,by,bw,bh
local function drawDiceIcon(dl, bx, by, bw, bh, col)
  local m=math.floor(math.min(bw,bh)*0.68)
  local rx=math.floor(bx+(bw-m)*0.5); local ry=math.floor(by+(bh-m)*0.5)
  local r=math.floor(m*0.18)
  reaper.ImGui_DrawList_AddRectFilled(dl, rx, ry, rx+m, ry+m, col, r)
  reaper.ImGui_DrawList_AddRect(dl, rx, ry, rx+m, ry+m, 0xFFFFFFFF, r, 0, 1.0)
  local dot=math.max(1, math.floor(m*0.10))
  local function dot2(fx,fy)
    local px=rx+math.floor(m*fx); local py=ry+math.floor(m*fy)
    reaper.ImGui_DrawList_AddCircleFilled(dl, px, py, dot, 0xFFFFFFFF)
  end
  dot2(0.25,0.25); dot2(0.75,0.25)
  dot2(0.50,0.50)
  dot2(0.25,0.75); dot2(0.75,0.75)
end

-- ══ Slider / Toggle wrappers ══════════════════════════════════
-- Alpha multiplier for DrawList calls (PushStyleVar(Alpha) does not affect them)
local _draw_alpha = 1.0
-- Exposed for ReaCurve_LFO (CURVE/QUANTIZE sections whose drawSep uses DrawList)
function M.setDrawAlpha(a) _draw_alpha = a end

local function drawIntSlider(ctx, id, label, v, vmin, vmax, w, dis, def, anc_sx, sld_h, extra_opts)
  local opts = { sld_h=sld_h or 16, gap=6, alpha=_draw_alpha, anchor_sx=anc_sx }
  if extra_opts then for k,vv in pairs(extra_opts) do opts[k]=vv end end
  return Slider.drawInt(ctx, id, label, v, vmin, vmax, w, dis, def, opts)
end
local function drawFloatSlider(ctx, id, label, v, vmin, vmax, fmt, w, dis, def, anc_sx, sld_h)
  return Slider.drawFloat(ctx, id, label, v, vmin, vmax, fmt, w, dis, def,
    { sld_h=sld_h or 16, gap=6, alpha=_draw_alpha, anchor_sx=anc_sx })
end
local function sliderPair(ctx, avw, gap, fn_a, fn_b) Slider.drawPair(ctx, avw, gap, fn_a, fn_b) end
local function drawToggle(ctx, id, w, h, la, lb, is_a)
  return Toggle.draw(ctx, id, w, h, la, lb, is_a)
end


-- ══ Public panels ═════════════════════════════════════════════

function M.drawPolygonPanel(ctx)
  local avw=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  local v=drawIntSlider(ctx,"sides","Sides",S.sides,Cfg.SIDES_MIN,Cfg.SIDES_MAX,avw,false,4,nil,16)
  if v~=S.sides then S.sides=v end
  reaper.ImGui_Dummy(ctx, avw, 5)
end

function M.drawGeometryPanel(ctx)
  local avw=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  sliderPair(ctx,avw,4,
    function(w,anc) local v=drawFloatSlider(ctx,"phase","Rotate",S.phase,0,1,"%.3f",w,false,0.0,anc); if v~=S.phase then S.phase=v end end,
    function(w,anc) local v=drawFloatSlider(ctx,"warp","Warp",S.warp,-1,1,"%.2f",w,false,0.0,anc); if v~=S.warp then S.warp=v end end)
  sliderPair(ctx,avw,4,
    function(w,anc) local v=drawFloatSlider(ctx,"align","Align to Line",S.align,0,1,"%.2f",w,false,0.0,anc); if v~=S.align then S.align=v end end,
    function(w,anc) local v=drawFloatSlider(ctx,"slide","Phase",S.path_slide,0,1,"%.2f",w,false,0.0,anc); if v~=S.path_slide then S.path_slide=v end end)
end

function M.drawAmplitudePanel(ctx)
  local avw=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  sliderPair(ctx,avw,4,
    function(w,anc) local v=drawFloatSlider(ctx,"amp","Amplitude",S.amp,0,1,"%.2f",w,false,1.0,anc); if v~=S.amp then S.amp=v end end,
    function(w,anc) local v=drawFloatSlider(ctx,"offset","Offset",S.offset,-1,1,"%.2f",w,false,0.0,anc); if v~=S.offset then S.offset=v end end)
  reaper.ImGui_Dummy(ctx, avw, 3)
end

function M.drawCyclesPanel(ctx)
  local avw=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  if drawToggle(ctx,"cmode",avw,22,"Fixed","Grid",S.cycle_mode=="fixed") then
    S.cycle_mode=(S.cycle_mode=="fixed") and "grid" or "fixed"
  end
  reaper.ImGui_Dummy(ctx, 1, 1)  -- space between toggle and slider
  local avw2=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  local is_grid=(S.cycle_mode=="grid")
  local v=drawIntSlider(ctx,"cycles","Cycle Number",S.cycles,Cfg.CYCLES_MIN,Cfg.CYCLES_MAX,avw2,is_grid,4,nil,16)
  if not is_grid and v~=S.cycles then S.cycles=v end
end

function M.drawShapePanel(ctx)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local items = {}
  for i, sh in ipairs(Cfg.SHAPES) do
    local sh_id = sh.id
    items[i] = {
      id = sh_id,
      draw_fn = function(dl2, ctx2, bx, by, bw, bh, active)
        Widgets.drawShapeIcon(dl2, ctx2, bx, by, bw, bh, sh_id,
          active and T.hx(T.C_TXT_PRI, 0.95) or T.hx(T.C_DISABLED, 0.75))
      end
    }
  end
  local new_shape = Widgets.drawViButtonRow(ctx, dl, items, S.segment_shape,
    { bh=30, gap=3, rounding=4, prefix="##sh" })
  if new_shape ~= S.segment_shape then S.segment_shape = new_shape end

  local is_bezier = (S.segment_shape == 5)
  local bez_a, bez_vis = sectionAlpha("bezier_tension", is_bezier)
  if bez_vis then
    _draw_alpha = bez_a
    local avw2 = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
    local tn   = drawFloatSlider(ctx, "b_tension", "Tension", S.bezier_tension, -1, 1, "%.2f", avw2, not is_bezier, 0.0, nil, 16)
    if is_bezier and tn ~= S.bezier_tension then S.bezier_tension = tn end
    _draw_alpha = 1.0
  end
end

-- Returns true when the Curve section (title + panel) should be visible.
function M.shouldShowCurve() return _ui_advanced end

function M.drawCurvePanel(ctx)
  -- No guard: visibility/fade is managed by sectionAlpha in the caller
  local dl   = reaper.ImGui_GetWindowDrawList(ctx)
  local items = {}
  for i, name in ipairs(Cfg.CURVE_MODES) do
    local display = (name == "Glitch") and "Fry" or name
    items[i] = { id = i-1, label = display }
  end
  S.curve_mode = Widgets.drawViButtonRow(ctx, dl, items, S.curve_mode,
    { bh=22, gap=3, rounding=3, border=0.8, prefix="##cm" })

  local avw2 = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local off  = (S.curve_mode == 0)
  local v    = drawFloatSlider(ctx, "c_amt", "Amount  (-=invert)", S.curve_amt, -1, 1, "%.2f", avw2, off, 0.0)
  if not off and v ~= S.curve_amt then S.curve_amt = v end
end

function M.drawQuantizePanel(ctx)
  local avw=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  -- Internal range 0-31; maps to display values 0, 2, 3, ..., 32 (value 1 never reachable).
  -- Slider pos 0 = off (0), pos 1..31 = levels 2..32.
  local function toSlider(q) return q==0 and 0 or (q-1) end
  local function fromSlider(s) return s==0 and 0 or (s+1) end
  local opts={
    display_fn = function(s) return s==0 and "0" or tostring(s+1) end,
    max_label  = "32",
  }
  local sv=drawIntSlider(ctx,"quantize","Quantize Levels",toSlider(S.quantize),0,31,avw,false,0,nil,nil,opts)
  local v=fromSlider(sv)
  if v~=S.quantize then S.quantize=v end
end

function M.drawAmpRangePanel(ctx)
  local dl    = reaper.ImGui_GetWindowDrawList(ctx)
  local items = {}
  for i, r in ipairs(Cfg.AMP_RANGES) do items[i] = { id=i, label=r.label } end
  local new = Widgets.drawViButtonRow(ctx, dl, items, S.amp_range, { bh=26, prefix="##ar" })
  if new ~= S.amp_range then S.amp_range = new end
end

-- ══ Radar ═════════════════════════════════════════════════════
-- Unit circle only. Drag = direct XY (absolute), no polar decomp.
-- Amp/offset are DECOUPLED from radar — polygon shown raw.

local function drawRadarEdge(dl,x1,y1,x2,y2,seg,cx,cy,maxR)
  local dx=x2-x1; local dy=y2-y1; local len=math.sqrt(dx*dx+dy*dy)
  if len<0.5 then reaper.ImGui_DrawList_AddLine(dl,x1,y1,x2,y2,0x00FFAAFF,2); return end
  local nx,ny=-dy/len,dx/len
  local mx2,my2=(x1+x2)*0.5-cx,(y1+y2)*0.5-cy
  if nx*mx2+ny*my2<0 then nx,ny=-nx,-ny end
  local SC=len*0.4; local CC=Geo.CurveSagitteScale(S.sides)*SC
  local is_wfold = ((S.curve_mode==4 or S.curve_mode==5) and S.curve_amt~=0)
  local STEPS = is_wfold and 20 or 40
  local devs={}
  for i=1,STEPS do
    local t=i/STEPS; devs[i]=Geo.SegmentDeviation(t,seg,SC,CC)
  end
  local px,py=x1,y1
  local amt = math.abs(S.curve_amt)
  for i=1,STEPS do
    local t=i/STEPS
    local bx=x1+dx*t+nx*devs[i]; local by=y1+dy*t+ny*devs[i]
    -- Glitch: clamp bx,by inside the circle to prevent overflow
    if S.curve_mode==5 and maxR then
      local ddx,ddy=bx-cx,by-cy; local dd=math.sqrt(ddx*ddx+ddy*ddy)
      if dd>maxR then local sc=maxR/dd; bx=cx+ddx*sc; by=cy+ddy*sc end
    end
    local col = 0x00FFAAFF
    if is_wfold and amt > 0.15 then
      local intensity = math.min(1.0, math.abs(devs[i]) / (SC*0.6+0.001))
      local ex2=bx-px; local ey2=by-py
      local elen2=math.sqrt(ex2*ex2+ey2*ey2)+0.001
      local nx3,ny3=-ey2/elen2, ex2/elen2
      local seed=math.abs(math.sin(math.floor(bx)*3.7+math.floor(by)*7.3))
      local spike_dir=seed>0.5 and 1.0 or -1.0
      local scale=math.min(1.0,(amt-0.15)/0.65)
      local spike_len=intensity*scale*SC*0.18
      if spike_len>0.5 then
        reaper.ImGui_DrawList_AddLine(dl,bx,by,
          bx+nx3*spike_len*spike_dir,by+ny3*spike_len*spike_dir,0xFF774466,1.0)
      end
      local ci2=math.floor(intensity*160)
      col=(math.min(255,0x44+ci2*2))*16777216+(math.max(0,0xFF-ci2))*65536+0x44*256+0xFF
    end
    reaper.ImGui_DrawList_AddLine(dl,px,py,bx,by,col,2); px,py=bx,by
  end
end


function M.drawRadarPanel(ctx)
  local dl = reaper.ImGui_GetWindowDrawList(ctx)
  
  -- ANTI-JITTER CORRECTION
  local window_w = reaper.ImGui_GetWindowWidth(ctx)
  local sb_w     = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize())
  local stable_avw = window_w - sb_w - 12
  local avw = stable_avw
  local fh  = reaper.ImGui_GetTextLineHeight(ctx)
  local btn_col_w = 120
  local gap_lr    = 20
  
  -- radar size
  local size = math.min(Cfg.RADAR_SIZE, stable_avw - btn_col_w - gap_lr)

	-- total width => radar + buttons
	local total_w = size + btn_col_w + gap_lr

	-- current position
	local cur_x, cur_y = reaper.ImGui_GetCursorScreenPos(ctx)

	-- center the full block (on stable_avw to avoid left/right jump)
	local offset_x = math.floor((stable_avw - total_w) * 0.5)
	reaper.ImGui_SetCursorScreenPos(ctx, cur_x + offset_x, cur_y)

	-- new origin
	local ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)

	-- button positions (fixed relative to radar)
	local btn_sx = ox + size + gap_lr * 0.5
  -- Center buttons in the remaining space to the right of the radar
  -- local space_right = avw - size
  -- local btn_sx  = ox + size + math.floor((space_right - btn_col_w) * 0.5)
  local maxR = size * 0.45
  local cx   = ox+size*0.5; local cy   = oy+size*0.5
  local N    = S.sides

  reaper.ImGui_DrawList_AddRectFilled(dl,ox,oy,ox+size,oy+size,T.hx(T.C_BG_PANEL))
  reaper.ImGui_DrawList_AddRect(dl,ox,oy,ox+size,oy+size,T.hx(T.C_BORDER,0.6),0,0,0.8)
  reaper.ImGui_DrawList_AddLine(dl,ox,cy,ox+size,cy,T.hx("#FFFFFF",0.07),1)
  reaper.ImGui_DrawList_AddLine(dl,cx,oy,cx,oy+size,T.hx("#FFFFFF",0.07),1)
  reaper.ImGui_DrawList_AddCircle(dl,cx,cy,maxR,T.hx("#FFFFFF",0.18),64)
  reaper.ImGui_DrawList_AddCircleFilled(dl,cx,cy,3,T.hx("#FFFFFF",0.25))

  local vx,vy={},{}
  for i=0,N-1 do
    local rx,ry=Geo.VRadarNorm(i); vx[i]=cx+rx*maxR; vy[i]=cy+ry*maxR
  end

  local mx,my=reaper.ImGui_GetMousePos(ctx)
  local HIT_R=10; local drag=S.drag
  if reaper.ImGui_IsMouseDoubleClicked(ctx,0) then
    for i=0,N-1 do
      if (mx-vx[i])^2+(my-vy[i])^2<=HIT_R*HIT_R then S.v_offsets[i]=nil; break end
    end
  end
  local in_radar=(mx>=ox and mx<=ox+size and my>=oy and my<=oy+size)
  if not drag.active and in_radar and reaper.ImGui_IsMouseClicked(ctx,0) then
    for i=0,N-1 do
      if (mx-vx[i])^2+(my-vy[i])^2<=HIT_R*HIT_R then
        drag.active=true; drag.idx=i; drag.last_mx=mx; drag.last_my=my
        drag.start_my=my
        drag.start_amp = S.v_offsets[i] and S.v_offsets[i][1] or 0.0
        drag.start_vy = vy[i]  -- initial Y screen position of the point
        break
      end
    end
  end
  local wheel=reaper.ImGui_GetMouseWheel(ctx)
  if wheel~=0 then
    local hit=-1
    for i=0,N-1 do
      if (mx-vx[i])^2+(my-vy[i])^2<=(HIT_R*2)^2 then hit=i; break end
    end
    if drag.active then hit=drag.idx end
    if hit>=0 then
      if not S.v_offsets[hit] then S.v_offsets[hit]={0,0} end
      S.v_offsets[hit][1]=math.max(-2.0,math.min(0.0,S.v_offsets[hit][1]+wheel*0.1))
      Geo.ClampOffsets(hit)
      local rx,ry=Geo.VRadarNorm(hit); vx[hit]=cx+rx*maxR; vy[hit]=cy+ry*maxR
    end
  end
  if drag.active then
    if reaper.ImGui_IsMouseDown(ctx,0) then
      local i = drag.idx
      if not S.v_offsets[i] then S.v_offsets[i] = {0, 0} end

      local shift = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Shift())
      local ctrl  = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Ctrl())
      local alt   = reaper.ImGui_IsKeyDown(ctx, reaper.ImGui_Mod_Alt())

      local target_x, target_y
      if shift then
        -- Shift : verrouille X, bouge verticalement
        local cur_rx, cur_ry = Geo.VRadarNorm(i)
        target_x = cx + cur_rx * maxR
        target_y = my
      elseif alt then
        -- Alt : verrouille Y, bouge horizontalement
        local cur_rx, cur_ry = Geo.VRadarNorm(i)
        target_x = mx
        target_y = cy + cur_ry * maxR
      else
        target_x, target_y = mx, my
      end

      local dx2, dy2 = target_x - cx, target_y - cy
      local dist = math.sqrt(dx2*dx2 + dy2*dy2) / maxR

      if ctrl then
        -- If the point is in the lower half-circle, increasing amplitude moves it down
        -- → invert the delta so that mouse up always moves the point up
        local sign = (drag.start_vy <= cy) and 1 or -1
        local delta = (drag.start_my - my) / maxR * sign
        S.v_offsets[i][1] = math.max(-2.0, math.min(0.0, drag.start_amp + delta))
      elseif i == 0 then
        local amp = -dy2 / maxR
        S.v_offsets[i][1] = math.max(-2.0, math.min(0.0, amp - 1.0))
      else
        local at_edge = (shift or alt) and dist >= 1.0
        if not at_edge then
          S.v_offsets[i][1] = math.max(-2.0, math.min(0.0, math.min(dist, 1.0) - 1.0))
          local angle = math.atan(dy2, dx2)
          local t_pos = ((angle + PI*0.5) / PI2 - S.phase) % 1.0
          S.v_offsets[i][2] = t_pos - Geo.Warp(i / S.sides)
        end
      end

      Geo.ClampOffsets(i)
      drag.last_mx, drag.last_my = mx, my
      local rx,ry=Geo.VRadarNorm(i); vx[i]=cx+rx*maxR; vy[i]=cy+ry*maxR
    else drag.active=false end
  end

  -- ── Hover tooltip: detect which point is hovered ─────────────
  do
    local hov_idx = -1
    if in_radar and not drag.active then
      for i = 0, N-1 do
        if (mx-vx[i])^2 + (my-vy[i])^2 <= HIT_R*HIT_R then
          hov_idx = i; break
        end
      end
    end
    if hov_idx ~= _radar_tip.idx then
      _radar_tip.idx     = hov_idx
      _radar_tip.t_start = (hov_idx >= 0) and reaper.time_precise() or nil
    end
  end

  reaper.ImGui_DrawList_PushClipRect(dl,ox,oy,ox+size,oy+size,true)
  for i=0,N-1 do reaper.ImGui_DrawList_AddLine(dl,cx,cy,vx[i],vy[i],T.hx("#FFFFFF",0.07),1) end
  for i=0,N-1 do drawRadarEdge(dl,vx[i],vy[i],vx[(i+1)%N],vy[(i+1)%N],i+1,cx,cy,maxR) end
  if S.path_slide~=0 then
    local bpx,bpy={},{}
    for i=0,N-1 do local rx,ry=Geo.VRadarDragged(i); bpx[i]=cx+rx*maxR; bpy[i]=cy+ry*maxR end
    for i=0,N-1 do
      local j=(i+1)%N; local x1,y1=bpx[i],bpy[i]; local x2,y2=bpx[j],bpy[j]
      local edx=x2-x1; local edy=y2-y1; local elen=math.sqrt(edx*edx+edy*edy)
      if elen>0.5 then
        local nx2,ny2=-edy/elen,edx/elen
        if nx2*(x1+x2)*0.5-cx+ny2*(y1+y2)*0.5-cy<0 then nx2,ny2=-nx2,-ny2 end
        local ppx,ppy=x1,y1
        for k=1,20 do
          local t=k/20; local dev=Geo.SegmentDeviation(t,i+1,elen*0.4,Geo.CurveSagitteScale(N)*maxR)
          local qx=x1+edx*t+nx2*dev; local qy=y1+edy*t+ny2*dev
          reaper.ImGui_DrawList_AddLine(dl,ppx,ppy,qx,qy,T.hx("#FFFFFF",0.20),1); ppx,ppy=qx,qy
        end
      end
    end
  end
  for i=0,N-1 do
    local col=Geo.VColor(i)
    if drag.active and drag.idx==i then
      reaper.ImGui_DrawList_AddCircle(dl,vx[i],vy[i],9,T.hx("#FFFFFF",0.65),16,1.5)
      reaper.ImGui_DrawList_AddText(dl,vx[i]+10,vy[i]-fh*0.5,T.hx("#FFFFFF",0.80),
        string.format("%.0f%%",Geo.VRadarY_raw(i)*100))
    end
    reaper.ImGui_DrawList_AddCircleFilled(dl,vx[i],vy[i],5,col)
    reaper.ImGui_DrawList_AddCircleFilled(dl,vx[i],vy[i],2,T.hx("#FFFFFF",0.80))
    local il=tostring(i+1); local lw3=reaper.ImGui_CalcTextSize(ctx,il)
    reaper.ImGui_DrawList_AddText(dl,vx[i]+(vx[i]>cx and -lw3-7 or 7),vy[i]-fh*0.5,T.hx("#FFFFFF",0.40),il)
  end
  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_SetCursorScreenPos(ctx,ox,oy)

  -- ── Hover tooltip (drawn on foreground, outside clip) ─────────
  if _radar_tip.idx >= 0 and _radar_tip.t_start then
    local elapsed = reaper.time_precise() - _radar_tip.t_start
    if elapsed >= RADAR_TIP_DELAY then
      local ft    = math.min(1.0, (elapsed - RADAR_TIP_DELAY) / RADAR_TIP_FADE)
      local tip_a = ft * ft * (3 - 2 * ft)  -- smoothstep
      if tip_a > 0.01 then
        local fg = reaper.ImGui_GetForegroundDrawList
                   and reaper.ImGui_GetForegroundDrawList(ctx) or dl
        local pad_x, pad_y = 10, 7
        local tip_lines = {
          { key="Ctrl",  desc="Amp only"  },
          { key="Shift", desc="Lock X"    },
          { key="Alt",   desc="Lock Y"    },
        }
        local key_w  = reaper.ImGui_CalcTextSize(ctx, "Shift") + 6
        local desc_w = 0
        for _, l in ipairs(tip_lines) do
          local w = reaper.ImGui_CalcTextSize(ctx, l.desc)
          if w > desc_w then desc_w = w end
        end
        local tip_w   = pad_x*2 + key_w + 8 + desc_w
        local line_h  = fh + 4
        local tip_h   = pad_y*2 + #tip_lines * line_h - 4

        -- Position: to the right of the cursor, vertically centered
        local tx = mx + 18
        local ty = my - math.floor(tip_h * 0.5)

        local function ac(hex, a) return T.hx(hex, (a or 1.0) * tip_a) end

        reaper.ImGui_DrawList_AddRectFilled(fg, tx, ty, tx+tip_w, ty+tip_h,
          ac(T.C_BG_MAIN, 0.96), 6)
        reaper.ImGui_DrawList_AddRect(fg, tx, ty, tx+tip_w, ty+tip_h,
          ac(T.C_BORDER, 0.60), 6, 0, 1.0)
        -- Modifier lines (no title)
        for j, l in ipairs(tip_lines) do
          local ly = ty + pad_y + (j-1) * line_h
          local kw  = reaper.ImGui_CalcTextSize(ctx, l.key)
          local kx  = tx + pad_x
          reaper.ImGui_DrawList_AddRectFilled(fg, kx-2, ly-1, kx+kw+4, ly+fh+1,
            ac(T.C_BG_PANEL2, 0.80), 3)
          reaper.ImGui_DrawList_AddText(fg, kx, ly, ac("#BBAAFF"), l.key)
          reaper.ImGui_DrawList_AddText(fg, tx + pad_x + key_w + 8, ly,
            ac(T.C_CFG_BASE, 0.85), l.desc)
        end
      end
    end
  end

  reaper.ImGui_InvisibleButton(ctx,"##radar_cap",size,size)

  -- Buttons on the RIGHT column (same height as radar)
  local btn_h   = 26
  local n_btns  = 3
  local btn_gap = math.floor((size - n_btns * btn_h) / (n_btns + 1))
  btn_sx = btn_sx + 4
  btn_sy = oy + btn_gap  -- first button
  local btn2_gap = 10
  local btn2_w   = math.floor((btn_col_w - btn2_gap) / 2)

  local function radarBtn(lbl,col_bg,col_hov,fn,w,bx,tip)
    reaper.ImGui_SetCursorScreenPos(ctx, bx or btn_sx, btn_sy)
    reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_FrameRounding(),5)
    reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_FrameBorderSize(),1.0)
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),        T.hx(col_bg))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_ButtonHovered(),  T.hx(col_hov))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_ButtonActive(),   T.hx(col_hov))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Text(),           T.hx("#DDDDFF",0.95))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Border(),         T.hx(col_hov,0.5))
    if reaper.ImGui_Button(ctx,lbl, w or btn_col_w, btn_h) then fn() end
    if tip and reaper.ImGui_IsItemHovered(ctx) then
      if not _btn_hover_times[lbl] then _btn_hover_times[lbl] = reaper.time_precise() end
      if (reaper.time_precise() - _btn_hover_times[lbl]) > BTN_TIP_DELAY then
        reaper.ImGui_SetTooltip(ctx, tip)
      end
    else
      _btn_hover_times[lbl] = nil
    end
    reaper.ImGui_PopStyleColor(ctx,5); reaper.ImGui_PopStyleVar(ctx,2)
  end

  -- Row 1: Random (dice) | Reset
  do
    local dl_r = reaper.ImGui_GetWindowDrawList(ctx)
    reaper.ImGui_SetCursorScreenPos(ctx, btn_sx, btn_sy)
    reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_FrameRounding(),5)
    reaper.ImGui_PushStyleVar(ctx,reaper.ImGui_StyleVar_FrameBorderSize(),1.0)
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Button(),        T.hx(VI_ON_BG))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_ButtonHovered(),  T.hx(VI_ON_HOV))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_ButtonActive(),   T.hx(VI_ON_HOV))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Text(),           T.hx("#00000000"))
    reaper.ImGui_PushStyleColor(ctx,reaper.ImGui_Col_Border(),         T.hx(VI_ON_BRD))
    local rbx,rby = reaper.ImGui_GetCursorScreenPos(ctx)
    local rclicked = reaper.ImGui_Button(ctx,"##rndrdr",btn2_w,btn_h)
    drawDiceIcon(dl_r,rbx,rby,btn2_w,btn_h,T.hx(VI_ON_BG))
    reaper.ImGui_PopStyleColor(ctx,5); reaper.ImGui_PopStyleVar(ctx,2)
    if rclicked then
      math.randomseed(math.floor(reaper.time_precise()*1000))
      randomizeRadar()
    end
    do
      local dice_tip = _ui_advanced
        and "Randomize all vertex positions and amplitudes"
        or  "Randomize polygon vertices"
      if reaper.ImGui_IsItemHovered(ctx) then
        if not _btn_hover_times["##rndrdr"] then _btn_hover_times["##rndrdr"] = reaper.time_precise() end
        if (reaper.time_precise() - _btn_hover_times["##rndrdr"]) > BTN_TIP_DELAY then
          reaper.ImGui_SetTooltip(ctx, dice_tip)
        end
      else
        _btn_hover_times["##rndrdr"] = nil
      end
    end
    radarBtn("Reset##rstvx", "#5C2800", "#8B3D00", function()
      S.resetOffsets()
      S.phase = 0; S.path_slide = 0; S.warp = 0; S.align = 0
    end, btn2_w, btn_sx + btn2_w + btn2_gap,
    _ui_advanced and "Reset polygon and sliders" or "Reset polygon and sliders")
    btn_sy = btn_sy + btn_h + btn_gap
  end

  -- Row 2: Flip Amp | Flip H
  radarBtn("Flip Amp##fa", "#1A2A4A", "#2A4A7A", function() Geo.applyFlipAmp();  _preset_modified = true end, btn2_w, btn_sx,
    _ui_advanced and "Mirror vertex amplitudes \ntop ↔ bottom" or "Mirror vertex amplitudes \ntop ↔ bottom")
  radarBtn("Flip H##fh",   "#1A2A4A", "#2A4A7A", function() Geo.flipH();          _preset_modified = true end, btn2_w, btn_sx + btn2_w + btn2_gap,
    _ui_advanced and "Mirror polygon around \nhorizontal axis" or "Mirror polygon around \nhorizontal axis")
  btn_sy = btn_sy + btn_h + btn_gap

  -- Row 3: Flip Time | Flip V
  radarBtn("Flip Time##ft", "#1A2A4A", "#2A4A7A", function() Geo.applyFlipTime(); _preset_modified = true end, btn2_w, btn_sx,
    _ui_advanced and "Reverse vertex order left ↔ right" or "Reverse vertex order left ↔ right")
  radarBtn("Flip V##fv",    "#1A2A4A", "#2A4A7A", function() Geo.flipV();          _preset_modified = true end, btn2_w, btn_sx + btn2_w + btn2_gap,
    _ui_advanced and "Mirror polygon around \nvertical axis" or "Mirror polygon around \nvertical axis")
  btn_sy = btn_sy + btn_h + btn_gap

  -- Advance cursor past radar row
  reaper.ImGui_SetCursorScreenPos(ctx,ox,oy+size+2)
  reaper.ImGui_Dummy(ctx,avw,2)

  -- Geometry sliders below radar (full width)
  local gavw=select(1,reaper.ImGui_GetContentRegionAvail(ctx))
  -- Row 1: Rotate | Phase
  sliderPair(ctx,gavw,4,
    function(w,anc) local v=drawFloatSlider(ctx,"phase2","Rotate",S.phase,0,1,"%.2f",w,false,0.0,anc); if v~=S.phase then S.phase=v end end,
    function(w,anc) local v=drawFloatSlider(ctx,"slide2","Phase",S.path_slide,0,1,"%.2f",w,false,0.0,anc); if v~=S.path_slide then S.path_slide=v end end)
  reaper.ImGui_Dummy(ctx, gavw, 3)
  -- Row 2: Align | Warp — advanced only, fade in/out via sectionAlpha
  local a_aw, vis_aw = sectionAlpha("radar_advanced", _ui_advanced)
  if vis_aw then
    _draw_alpha = a_aw
    if a_aw < 1.0 then reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), a_aw) end
    sliderPair(ctx,gavw,4,
      function(w,anc) local v=drawFloatSlider(ctx,"align2","Align",S.align,0,1,"%.2f",w,false,0.0,anc); if v~=S.align then S.align=v end end,
      function(w,anc) local v=drawFloatSlider(ctx,"warp2","Warp",S.warp,-1,1,"%.2f",w,false,0.0,anc); if v~=S.warp then S.warp=v end end)
    reaper.ImGui_Dummy(ctx, gavw, 3)
    if a_aw < 1.0 then reaper.ImGui_PopStyleVar(ctx) end
    _draw_alpha = 1.0
  end
end

-- ══ Preview ═══════════════════════════════════════════════════
-- Shows VLFO (with amp/offset applied for display).
-- Curve mode is applied via rawY + normalization (same as write).

local PREVIEW_CYCLES = 2

-- buildPreviewPts: EXACTLY the same formula as LFOWrite so preview = write.
-- No curve → Generator.buildPreview with VLFO control points.
-- With curve → sub-sample: VLFO base + sagit*soft_dir curve, same gscale.
local function buildPreviewPts()
  local N         = S.sides
  local has_curve = S.curve_mode>0 and S.curve_amt~=0
  local is_quant  = S.quantize>=2

  local t0=Geo.VTX(0)  -- anchor: vertex 0 always at t=0 in preview

  if not has_curve then
    local range=Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
    local function toPreview(v01) return range.lo + v01*(range.hi-range.lo) end
    local ctrl={}
    for c=0,PREVIEW_CYCLES-1 do
      for i=0,N-1 do
        ctrl[#ctrl+1]={tn=c+(Geo.VTX(i)-t0)%1.0,v=toPreview(Geo.VLFO(i)),shape=S.segment_shape,tension=S.bezier_tension,_i=i}
      end
    end
    ctrl[#ctrl+1]={tn=PREVIEW_CYCLES*1.0,v=toPreview(Geo.VLFO(0)),shape=S.segment_shape,tension=S.bezier_tension,_i=-1}
    table.sort(ctrl, function(a,b)
      if math.abs(a.tn-b.tn)<1e-9 then
        if a._i==-1 then return false end
        if b._i==-1 then return true end
        return a._i<b._i
      end
      return a.tn<b.tn
    end)
    return Generator.buildPreview(ctrl)
  end

  -- With curve: sub-sample
  local SUB = has_curve and math.max(2, S.precision*3) or 1
  local sagit=Geo.CurveSagitteScale(N)
  local gscale=(SUB>1) and Geo.computeCurveScale() or 1.0
  local pts={}
  local gen_id=0
  local sv={}
  for i=0,N-1 do sv[#sv+1]={idx=i, t=(Geo.VTX(i)-t0)%1.0} end
  table.sort(sv, function(a,b)
    if math.abs(a.t-b.t)<1e-9 then return a.idx<b.idx end
    return a.t<b.t
  end)
  local rangeB=Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
  for c=0,PREVIEW_CYCLES-1 do
    for si=1,#sv do
      local i=sv[si].idx; local i_next=sv[si%#sv+1].idx
      local y1=Geo.VLFO(i); local y2=Geo.VLFO(i_next)
      local t1=sv[si].t; local t2=sv[si%#sv+1].t
      if t2<t1 then t2=1.0 end
      if math.abs(t2-t1)<1e-4 then
        gen_id=gen_id+1; pts[#pts+1]={tn=c+t1, v=rangeB.lo+y1*(rangeB.hi-rangeB.lo), _i=gen_id}
        gen_id=gen_id+1; pts[#pts+1]={tn=c+t1, v=rangeB.lo+y2*(rangeB.hi-rangeB.lo), _i=gen_id}
      else
        for k=0,SUB-1 do
          local t=k/SUB; local xt=t1+(t2-t1)*t
          local yr1=Geo.VRadarY_raw(i); local yr2=Geo.VRadarY_raw(i_next)
          local base_raw=yr1+(yr2-yr1)*Geo.ShapeT(t)
          local angle_t=(t1+(t2-t1)*t+S.phase)*PI2-PI*0.5
          local co=Geo.CurveOff(t,si)
          local y_raw
          if S.curve_mode==4 then
            local scale = 1.0 + math.abs(co) * 2.0
            y_raw = Geo.wavefold(base_raw * scale)
          else
            local cv=co*sagit*(-math.sin(angle_t))*gscale
            y_raw=math.max(-1,math.min(1, base_raw+cv))
          end
          local y01=Geo.Quantize(math.max(0,math.min(1, 0.5+(y_raw*S.amp+S.offset)*0.5)))
          gen_id=gen_id+1; pts[#pts+1]={tn=c+xt, v=rangeB.lo+y01*(rangeB.hi-rangeB.lo), _i=gen_id}
        end
      end
    end
  end
  local rangeC=Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
  gen_id=gen_id+1; pts[#pts+1]={tn=PREVIEW_CYCLES*1.0, v=rangeC.lo+Geo.VLFO(0)*(rangeC.hi-rangeC.lo), _i=gen_id}
  table.sort(pts, function(a,b)
    if math.abs(a.tn-b.tn)<1e-10 then return a._i<b._i end
    return a.tn<b.tn
  end)
  return pts
end

function M.drawPreviewPanel(ctx)
  local dl  = reaper.ImGui_GetWindowDrawList(ctx)
  
  -- ANTI-JITTER CORRECTION
  local window_w = reaper.ImGui_GetWindowWidth(ctx)
  local sb_w     = reaper.ImGui_GetStyleVar(ctx, reaper.ImGui_StyleVar_ScrollbarSize())
  local avw = window_w - sb_w - 12
  
  local fhp = reaper.ImGui_GetTextLineHeight(ctx)
  local Y_LBL_W = 30          -- left margin reserved for Y labels
  local X_MAR_R = 6           -- right margin
  local X_LBL_H = fhp + 4    -- bottom strip for X labels
  local w  = avw - Y_LBL_W - X_MAR_R   -- box width
  local h  = Cfg.PREVIEW_H
  local ox, oy = reaper.ImGui_GetCursorScreenPos(ctx)
  local bx = ox + Y_LBL_W    -- box left edge
  local N  = S.sides

  -- Box background + border
  reaper.ImGui_DrawList_AddRectFilled(dl, bx,oy, bx+w,oy+h, T.hx(T.C_BG_PANEL))
  reaper.ImGui_DrawList_AddRect(dl, bx,oy, bx+w,oy+h, T.hx(T.C_BORDER,0.6), 0,0,0.8)

  -- Y axis: grid lines inside box + labels outside left
  local rng = Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
  local y_marks = {
    {v01=1.0, label="+100", a_line=0.18, a_txt=0.55},
    {v01=0.75,label="+50",  a_line=0.10, a_txt=0.42},
    {v01=0.5, label="0",    a_line=0.28, a_txt=0.70},
    {v01=0.25,label="-50",  a_line=0.10, a_txt=0.42},
    {v01=0.0, label="-100", a_line=0.18, a_txt=0.55},
  }
  for _,m in ipairs(y_marks) do
    local sy_m  = oy + h*(1-m.v01)
    local is_zero = (m.v01 == 0.5)
    reaper.ImGui_DrawList_AddLine(dl, bx,sy_m, bx+w,sy_m,
      T.hx("#FFFFFF", m.a_line), is_zero and 1.2 or 0.8)
    -- Tick between label and box
    reaper.ImGui_DrawList_AddLine(dl, bx-4,sy_m, bx,sy_m, T.hx("#FFFFFF", m.a_txt*0.6), 1)
    -- Label: right-aligned just left of tick, vertically centered on line
    local lw2  = reaper.ImGui_CalcTextSize(ctx, m.label)
    local lbl_y = math.max(oy, math.min(oy+h-fhp, sy_m - fhp*0.5))
    reaper.ImGui_DrawList_AddText(dl, bx - lw2 - 6, lbl_y, T.hx("#FFFFFF", m.a_txt), m.label)
  end

  -- X axis: vertical dividers inside box + tick + label below box
  for c = 0, PREVIEW_CYCLES-1 do
    local x_marks = {{f=0,lbl="0"},{f=0.25,lbl="25"},{f=0.5,lbl="50"},{f=0.75,lbl="75"}}
    for _, xm in ipairs(x_marks) do
      local xfrac = (c + xm.f) / PREVIEW_CYCLES
      local px2   = bx + xfrac * w
      local is_start = (xm.f == 0)
      local line_a   = is_start and (c==0 and 0.0 or 0.20) or 0.07
      if line_a > 0 then
        reaper.ImGui_DrawList_AddLine(dl, px2,oy, px2,oy+h, T.hx("#FFFFFF",line_a), 1)
      end
      -- Tick below box
      reaper.ImGui_DrawList_AddLine(dl, px2,oy+h, px2,oy+h+3, T.hx("#FFFFFF",0.35), 1)
      -- Label centered on tick, clamped inside box width
      local lw3 = reaper.ImGui_CalcTextSize(ctx, xm.lbl)
      local lx3 = math.max(bx, math.min(bx+w-lw3, px2 - lw3*0.5))
      reaper.ImGui_DrawList_AddText(dl, lx3, oy+h+4, T.hx("#FFFFFF",0.40), xm.lbl)
    end
  end

  if S.quantize>=2 then
    -- Lines scaled to the active amplitude range (lo..hi in normalised [0,1] space)
    local q_lo=rng.lo; local q_hi=rng.hi
    for q=0,S.quantize-1 do
      local qv=q_lo+(q_hi-q_lo)*(q/(S.quantize-1))
      local qy=oy+h*(1-qv)
      reaper.ImGui_DrawList_AddLine(dl,bx,qy,bx+w,qy,T.hx(T.C_MRF_SEL,0.18),1)
    end
  end

  reaper.ImGui_DrawList_PushClipRect(dl,bx,oy,bx+w,oy+h,true)

  -- Curve
  local dense=buildPreviewPts()
  if #dense>=2 then
    local prev_x,prev_y
    for _,sp in ipairs(dense) do
      local fx=bx+(sp.tn/PREVIEW_CYCLES)*w
      local fy=oy+h-math.max(0,math.min(1,sp.v))*h
      if prev_x then reaper.ImGui_DrawList_AddLine(dl,prev_x,prev_y,fx,fy,0x00FFAAFF,2) end
      prev_x,prev_y=fx,fy
    end
  end

  -- Vertex dots (anchored so vertex 0 is always at t=0)
  local t0_d=Geo.VTX(0)
  local rng_d=Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
  for c=0,PREVIEW_CYCLES-1 do
    for i=0,N-1 do
      local lfo=rng_d.lo+Geo.VLFO(i)*(rng_d.hi-rng_d.lo); local tx2=(Geo.VTX(i)-t0_d)%1.0
      local sx=bx+((tx2+c)/PREVIEW_CYCLES)*w; local sy=oy+h*(1-lfo)
      local col=Geo.VColor(i)
      reaper.ImGui_DrawList_AddLine(dl,sx,oy+h,sx,oy+h-7,col,1.8)
      local col_faded=(col&0xFFFFFF00)|math.floor(((col&0xFF)*0.55)+0.5)
      reaper.ImGui_DrawList_AddCircleFilled(dl,sx,sy,3.5,col_faded)
      reaper.ImGui_DrawList_AddCircleFilled(dl,sx,sy,1.5,T.hx("#FFFFFF",0.55))
    end
  end

  reaper.ImGui_DrawList_PopClipRect(dl)
  reaper.ImGui_InvisibleButton(ctx,"##preview_cap",avw,h)
  reaper.ImGui_Dummy(ctx,avw,X_LBL_H)
end

local function drawFolderIcon(dl, x, y, h, col)
  local w  = math.floor(h * 1.25)
  local th = math.floor(h * 0.26)
  local tw = math.floor(w * 0.44)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y + th - 1, x + w, y + h, col, 1.5)
  reaper.ImGui_DrawList_AddRectFilled(dl, x, y,           x + tw, y + th + 1, col, 1.0)
end

function M.drawPresetBar(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))

  if _preset_list_dirty then
    _preset_list = LFOPresets.list()
    _preset_list_dirty = false
    local found = false
    for _, n in ipairs(_preset_list) do if n == _preset_sel then found=true; break end end
    if not found and _preset_sel ~= "" then _preset_sel = "" end
  end
  -- Capture snapshot on the first frame of each session
  if not _snapshot_ready then
    _preset_snapshot = stateFingerprint()
    _snapshot_ready  = true
  end
  _preset_modified = (stateFingerprint() ~= _preset_snapshot)

  local btn_w = 52; local gap = 4; local dice_w = 42
  -- Layout: [Preset dropdown] [Init] [Save] [🎲]
  local combo_w = math.max(60, avw - btn_w*2 - dice_w - gap*3)
  local open_save_popup = false
  local _open_unsaved_popup = false

  -- Opens the native OS save dialog in the LFOPresets folder.
  -- Returns the saved preset name on success, or (nil, reason) on failure/cancel.
  -- reason == "no_js_api" means js_ReaScriptAPI is not installed → use modal fallback.
  local function saveWithFileDialog()
    if not reaper.JS_Dialog_BrowseForSaveFile then return nil, "no_js_api" end
    local dir = LFOPresets.getDir() or ""
    local initial = (_preset_sel ~= "") and (_preset_sel:match("([^/]+)$") or _preset_sel) or ""
    local ok, path = reaper.JS_Dialog_BrowseForSaveFile("Save LFO Preset", dir, initial, "Lua preset\0*.lua\0\0")
    if ok ~= 1 or not path or path == "" then return nil, "cancelled" end
    -- Normalize separators before comparison (Windows returns backslashes)
    local dir_n  = dir:gsub("\\", "/")
    local path_n = path:gsub("\\", "/")
    local rel
    if dir_n ~= "" and path_n:sub(1, #dir_n):lower() == dir_n:lower() then
      rel = path_n:sub(#dir_n + 1)
    else
      -- Saved outside preset dir: keep only the filename
      rel = path_n:match("([^/]+)$") or ""
    end
    rel = rel:gsub("%.lua$", ""):gsub("^/+", "")
    if rel == "" then return nil, "empty" end
    local saved, err = LFOPresets.save(rel, true)
    if saved then
      _preset_sel = saved; _preset_modified = false
      _preset_list_dirty = true; _preset_snapshot = stateFingerprint()
      Logger.ok("Saved '" .. saved .. "'")
      return saved
    end
    Logger.error("Save failed: " .. (err or "?"))
    return nil, err
  end

  Widgets.pushComboStyle(ctx)

  -- ── Preset dropdown with arrow/star indicator ─────────────
  reaper.ImGui_SetNextItemWidth(ctx, combo_w)
  local pfx_cur = _preset_modified and "* " or (_preset_sel ~= "" and "> " or "")
  local preview = pfx_cur .. (_preset_sel ~= "" and _preset_sel or "Default")
  if reaper.ImGui_BeginCombo(ctx, "##pcombo", preview) then
    do
      -- Build folder structure (list is already sorted: folders first)
      local root_items  = {}
      local folder_map  = {}
      local folder_order = {}
      for _, name in ipairs(_preset_list) do
        local folder = name:match("^(.+)/[^/]+$")
        if folder then
          if not folder_map[folder] then
            folder_map[folder] = {}
            folder_order[#folder_order+1] = folder
          end
          folder_map[folder][#folder_map[folder]+1] = name
        else
          root_items[#root_items+1] = name
        end
      end

      local sel_folder = _preset_sel ~= "" and _preset_sel:match("^(.+)/[^/]+$") or nil

      -- helper: load or queue unsaved action
      local function doLoad(name)
        if _preset_modified then
          _unsaved_action = {type="load", arg=name}
          _open_unsaved_popup = true
        else
          local ok, err = LFOPresets.load(name)
          if ok then _preset_sel=name; _preset_snapshot=stateFingerprint()
          else Logger.error("Load: "..(err or "?")) end
        end
      end

      -- ── folder submenus ────────────────────────────────────────
      local dl2    = reaper.ImGui_GetWindowDrawList(ctx)
      local fh2    = reaper.ImGui_GetFrameHeight(ctx)
      local icon_h = math.floor(fh2 * 0.52)
      local icon_col = T.hx(T.C_CFG_BASE, 0.55)
      for _, folder in ipairs(folder_order) do
        local has_sel = (sel_folder == folder)
        local pfx = has_sel and (_preset_modified and "* " or "> ") or "  "
        if reaper.ImGui_BeginMenu(ctx, "     " .. pfx .. folder) then
          for _, name in ipairs(folder_map[folder]) do
            local display_name = name:match("[^/]+$") or name
            local is_cur = (name == _preset_sel)
            local p = is_cur and (_preset_modified and "* " or "> ") or "  "
            if is_cur then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
            if reaper.ImGui_Selectable(ctx, p..display_name.."##ps_"..name, is_cur) then doLoad(name) end
            if is_cur then reaper.ImGui_PopStyleColor(ctx); reaper.ImGui_SetItemDefaultFocus(ctx) end
          end
          reaper.ImGui_EndMenu(ctx)
        end
        -- draw folder icon over the leading spaces (after BeginMenu so rect is valid)
        local bx, by = reaper.ImGui_GetItemRectMin(ctx)
        local _,  bh = reaper.ImGui_GetItemRectSize(ctx)
        drawFolderIcon(dl2, bx + 2, by + math.floor((bh - icon_h) * 0.5), icon_h, icon_col)
      end

      -- ── separator then root presets ───────────────────────────
      if #folder_order > 0 and #root_items > 0 then reaper.ImGui_Separator(ctx) end
      for _, name in ipairs(root_items) do
        local is_cur = (name == _preset_sel)
        local p = is_cur and (_preset_modified and "* " or "> ") or "  "
        if is_cur then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
        if reaper.ImGui_Selectable(ctx, p..name.."##ps_"..name, is_cur) then doLoad(name) end
        if is_cur then reaper.ImGui_PopStyleColor(ctx); reaper.ImGui_SetItemDefaultFocus(ctx) end
      end
    end
    if #_preset_list == 0 then reaper.ImGui_TextDisabled(ctx,"(no presets)") end
    reaper.ImGui_Separator(ctx)
    if reaper.ImGui_Selectable(ctx,"+ Save as...##psas",false) then
      local _, reason = saveWithFileDialog()
      if reason == "no_js_api" then _preset_name_buf=""; open_save_popup=true end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  Widgets.popComboStyle(ctx)
  -- Open the popup AFTER EndCombo (otherwise ImGui ignores it)
  if _open_unsaved_popup then reaper.ImGui_OpenPopup(ctx, "##unsaved_warn") end
  reaper.ImGui_SameLine(ctx, 0, gap)

  -- ── Preset action buttons (title-bar aesthetic: dark + violet hover) ──
  reaper.ImGui_PushStyleVar(ctx,  reaper.ImGui_StyleVar_FrameRounding(),   4)
  reaper.ImGui_PushStyleVar(ctx,  reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(VI_ON_BRD, 0.85))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(VI_ON_HOV, 0.72))
  reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(VI_ON_BRD, 0.35))

  -- ── Init button ──────────────────────────────────────────
  do
    local ibx, iby = reaper.ImGui_GetCursorScreenPos(ctx)
    local fh = reaper.ImGui_GetFrameHeight(ctx)
    local i_hov = reaper.ImGui_IsMouseHoveringRect(ctx, ibx, iby, ibx+btn_w, iby+fh)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), i_hov and T.hx(T.C_TXT_PRI) or T.hx(T.C_CFG_BASE, 0.88))
    if reaper.ImGui_Button(ctx, "Init##initbtn", btn_w, 0) then
      if _preset_modified then
        _unsaved_action = {type="init"}
        reaper.ImGui_OpenPopup(ctx, "##unsaved_warn")
      else
        LFOPresets.initDefaults()
        _preset_sel=""; _preset_snapshot=stateFingerprint()
        Logger.ok("Reset to defaults")
      end
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_SameLine(ctx, 0, gap)

  -- ── Save button ──────────────────────────────────────────
  do
    local sbx, sby = reaper.ImGui_GetCursorScreenPos(ctx)
    local fh = reaper.ImGui_GetFrameHeight(ctx)
    local s_hov = reaper.ImGui_IsMouseHoveringRect(ctx, sbx, sby, sbx+btn_w, sby+fh)
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), s_hov and T.hx(T.C_TXT_PRI) or T.hx(T.C_CFG_BASE, 0.88))
    if reaper.ImGui_Button(ctx, "Save##psavebtn", btn_w, 0) then
      local _, reason = saveWithFileDialog()
      if reason == "no_js_api" then _preset_name_buf=""; open_save_popup=true end
    end
    reaper.ImGui_PopStyleColor(ctx, 1)
  end

  reaper.ImGui_SameLine(ctx, 0, gap)

  -- ── Randomize button (dice) ──────────────────────────────
  do
    local dl2=reaper.ImGui_GetWindowDrawList(ctx)
    local bx2,by2=reaper.ImGui_GetCursorScreenPos(ctx)
    local clicked=reaper.ImGui_Button(ctx,"##rnd_btn",dice_w,0)
    local bh2=select(2,reaper.ImGui_GetItemRectSize(ctx))
    local is_hov = reaper.ImGui_IsItemHovered(ctx)
    drawDiceIcon(dl2,bx2,by2,dice_w,bh2,T.hx(VI_ON_BRD, is_hov and 0.85 or 0.42))
    if clicked then
      math.randomseed(math.floor(reaper.time_precise()*1000))
      randomizeAll()
      Logger.ok("Randomized!")
    end
  end

  reaper.ImGui_PopStyleColor(ctx, 4)
  reaper.ImGui_PopStyleVar(ctx, 2)

  -- Helper : push style for themed modals
  local function pushModalStyle()
    -- Dim overlay fades out in sync with popup close animation
    local _fa = 1.0
    if _popup_closing and _popup_close_t then
      local _t = math.min(1.0, (reaper.time_precise() - _popup_close_t) / POPUP_FADE_DUR)
      _fa = 1.0 - sectionEaseOut(_t)
    end
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ModalWindowDimBg(), T.hx("#FFFFFF", 0.12 * _fa))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_PopupBg(),       T.hx(T.C_BG_MAIN))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBg(),       T.hx(T.C_BG_PANEL))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_TitleBgActive(), T.hx(T.C_BG_PANEL2))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),        T.hx(VI_ON_BRD, 0.45))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx(T.C_TXT_PRI))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBg(),       T.hx(T.C_BG_PANEL2))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_FrameBgHovered(),T.hx(VI_ON_HOV, 0.30))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx(T.C_BG_PANEL2))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx(VI_ON_HOV, 0.55))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx(VI_ON_HOV, 0.72))
    reaper.ImGui_PushStyleVar(ctx,  reaper.ImGui_StyleVar_WindowRounding(),  6)
    reaper.ImGui_PushStyleVar(ctx,  reaper.ImGui_StyleVar_WindowPadding(),   14, 12)
    reaper.ImGui_PushStyleVar(ctx,  reaper.ImGui_StyleVar_FrameRounding(),   4)
    reaper.ImGui_PushStyleVar(ctx,  reaper.ImGui_StyleVar_FrameBorderSize(), 1.0)
  end
  local function popModalStyle()
    reaper.ImGui_PopStyleColor(ctx, 11)
    reaper.ImGui_PopStyleVar(ctx, 4)
  end

  -- Compute popup fade alpha for this frame (ease out on cancel)
  local function getPopupFade()
    if not _popup_closing then return 1.0, false end
    local t = math.min(1.0, (reaper.time_precise() - _popup_close_t) / POPUP_FADE_DUR)
    return 1.0 - sectionEaseOut(t), t >= 1.0
  end

  -- ── Unsaved warning modal ─────────────────────────────────
  pushModalStyle()
  do
    local wx,wy = reaper.ImGui_GetWindowPos(ctx)
    local ww    = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_SetNextWindowPos(ctx, wx+ww*0.5, wy+40, reaper.ImGui_Cond_Always(), 0.5, 0.0)
  end
  if reaper.ImGui_BeginPopupModal(ctx,"##unsaved_warn",nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    local fa, fade_done = getPopupFade()
    local pushed_alpha = false
    if _popup_closing then
      if fade_done then
        reaper.ImGui_CloseCurrentPopup(ctx)
        _popup_closing = false; _popup_close_t = nil
      end
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), fa)
      pushed_alpha = true
    end
    reaper.ImGui_TextColored(ctx, T.hx("#FF8800"), "Unsaved changes")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      select(1,reaper.ImGui_GetCursorScreenPos(ctx))-14,
      select(2,reaper.ImGui_GetCursorScreenPos(ctx)),
      select(1,reaper.ImGui_GetCursorScreenPos(ctx))+280,
      select(2,reaper.ImGui_GetCursorScreenPos(ctx)),
      T.hx(T.C_BORDER,0.5), 1)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextColored(ctx, T.hx(T.C_CFG_BASE, 0.8), "Save before continuing?")
    reaper.ImGui_Spacing(ctx)
    if reaper.ImGui_Button(ctx,"Save first##uw_s",104,0) and not _popup_closing then
      local saved, reason = saveWithFileDialog()
      if reason == "no_js_api" then
        _preset_name_buf=""; open_save_popup=true
        reaper.ImGui_CloseCurrentPopup(ctx)
      elseif saved then
        -- Save succeeded via file dialog: execute pending action then close
        if _unsaved_action then
          if _unsaved_action.type=="load" then
            local ok,err=LFOPresets.load(_unsaved_action.arg)
            if ok then _preset_sel=_unsaved_action.arg; _preset_snapshot=stateFingerprint()
            else Logger.error("Load: "..(err or "?")) end
          elseif _unsaved_action.type=="init" then
            LFOPresets.initDefaults(); _preset_sel=""; _preset_snapshot=stateFingerprint()
            Logger.ok("Reset to defaults")
          end
          _unsaved_action=nil
        end
        reaper.ImGui_CloseCurrentPopup(ctx)
      end
      -- if cancelled, stay in the popup so user can choose another option
    end
    reaper.ImGui_SameLine(ctx,0,6)
    if reaper.ImGui_Button(ctx,"Discard##uw_d",104,0) and not _popup_closing then
      if _unsaved_action then
        if _unsaved_action.type=="load" then
          local ok,err=LFOPresets.load(_unsaved_action.arg)
          if ok then _preset_sel=_unsaved_action.arg; _preset_snapshot=stateFingerprint()
          else Logger.error("Load: "..(err or "?")) end
        elseif _unsaved_action.type=="init" then
          LFOPresets.initDefaults(); _preset_sel=""; _preset_snapshot=stateFingerprint()
          Logger.ok("Reset to defaults")
        end
        _unsaved_action=nil
      end
      reaper.ImGui_CloseCurrentPopup(ctx)
    end
    reaper.ImGui_SameLine(ctx,0,6)
    if reaper.ImGui_Button(ctx,"Cancel##uw_c",72,0) and not _popup_closing then
      _unsaved_action=nil
      _popup_closing = true; _popup_close_t = reaper.time_precise()
    end
    if pushed_alpha then reaper.ImGui_PopStyleVar(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end
  popModalStyle()

  -- Open modal deferred
  if open_save_popup then reaper.ImGui_OpenPopup(ctx, "Save Preset##ps_modal") end

  -- ── Save popup ─────────────────────────────────────────────
  pushModalStyle()
  do
    local wx,wy = reaper.ImGui_GetWindowPos(ctx)
    local ww    = reaper.ImGui_GetWindowSize(ctx)
    reaper.ImGui_SetNextWindowPos(ctx, wx+ww*0.5, wy+40, reaper.ImGui_Cond_Always(), 0.5, 0.0)
  end
  if reaper.ImGui_BeginPopupModal(ctx, "Save Preset##ps_modal", nil,
      reaper.ImGui_WindowFlags_AlwaysAutoResize()) then
    local fa, fade_done = getPopupFade()
    local pushed_alpha = false
    if _popup_closing then
      if fade_done then
        reaper.ImGui_CloseCurrentPopup(ctx)
        _popup_closing = false; _popup_close_t = nil
      end
      reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_Alpha(), fa)
      pushed_alpha = true
    end

    reaper.ImGui_TextColored(ctx, T.hx(T.C_MRF_SEL), "Save Preset")
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
      select(1,reaper.ImGui_GetCursorScreenPos(ctx))-14,
      select(2,reaper.ImGui_GetCursorScreenPos(ctx)),
      select(1,reaper.ImGui_GetCursorScreenPos(ctx))+268,
      select(2,reaper.ImGui_GetCursorScreenPos(ctx)),
      T.hx(T.C_BORDER,0.5), 1)
    reaper.ImGui_Spacing(ctx)
    reaper.ImGui_TextColored(ctx, T.hx(T.C_CFG_BASE, 0.8), "Preset name:")
    reaper.ImGui_SameLine(ctx, 0, 6)
    reaper.ImGui_TextDisabled(ctx, "(folder/name)")
    reaper.ImGui_SetNextItemWidth(ctx, 240)
    if reaper.ImGui_IsWindowAppearing(ctx) then
      _preset_name_buf = ""
      reaper.ImGui_SetKeyboardFocusHere(ctx)
    end
    local ch, buf2 = reaper.ImGui_InputText(ctx, "##ps_ni", _preset_name_buf)
    if ch then _preset_name_buf = buf2 end

    reaper.ImGui_Spacing(ctx)

    do
      local is_overwrite = _preset_overwrite_name ~= nil
      local enter_pressed = not _popup_closing and not is_overwrite and reaper.ImGui_IsKeyPressed(ctx,
        reaper.ImGui_Key_Enter and reaper.ImGui_Key_Enter() or 13, false)

      if is_overwrite then reaper.ImGui_BeginDisabled(ctx) end
      if (reaper.ImGui_Button(ctx, "Save##ps_ok", 116, 0) or enter_pressed) and not _popup_closing then
        if _preset_name_buf ~= "" then
          if LFOPresets.exists(_preset_name_buf) then
            _preset_overwrite_name = _preset_name_buf
          else
            local saved, err = LFOPresets.save(_preset_name_buf, false)
            if saved then
              _preset_sel = saved; _preset_modified = false; _preset_list_dirty = true; _preset_snapshot = stateFingerprint()
              Logger.ok("Saved '" .. saved .. "'")
              reaper.ImGui_CloseCurrentPopup(ctx)
            else Logger.error("Save failed: " .. (err or "?")) end
          end
        end
      end
      if is_overwrite then reaper.ImGui_EndDisabled(ctx) end
      reaper.ImGui_SameLine(ctx, 0, 8)
      if reaper.ImGui_Button(ctx, "Cancel##ps_ca", 116, 0) and not _popup_closing then
        _preset_overwrite_name = nil
        _popup_closing = true; _popup_close_t = reaper.time_precise()
      end

      if _preset_overwrite_name then
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_DrawList_AddLine(reaper.ImGui_GetWindowDrawList(ctx),
          select(1,reaper.ImGui_GetCursorScreenPos(ctx))-14,
          select(2,reaper.ImGui_GetCursorScreenPos(ctx)),
          select(1,reaper.ImGui_GetCursorScreenPos(ctx))+268,
          select(2,reaper.ImGui_GetCursorScreenPos(ctx)),
          T.hx(T.C_BORDER,0.5), 1)
        reaper.ImGui_Spacing(ctx)
        reaper.ImGui_TextColored(ctx, T.hx(T.C_CFG_BASE, 0.9),
          "'"..(_preset_overwrite_name or "").."' already exists. Overwrite?")
        reaper.ImGui_Spacing(ctx)
        local ow_w = 150
        local popup_w = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
        reaper.ImGui_SetCursorPosX(ctx, math.floor((popup_w - ow_w) * 0.5) + 14)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Button(),        T.hx("#A84800"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonHovered(), T.hx("#D06000"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ButtonActive(),  T.hx("#F07000"))
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(),          T.hx("#FFFFFF"))
        reaper.ImGui_PushStyleVar(ctx,   reaper.ImGui_StyleVar_FrameBorderSize(), 0)
        if reaper.ImGui_Button(ctx, "Overwrite##ps_ow2", ow_w, 0) then
          local s2, e2 = LFOPresets.save(_preset_overwrite_name, true)
          if s2 then
            _preset_sel = s2; _preset_modified = false
            _preset_list_dirty = true; _preset_snapshot = stateFingerprint()
            Logger.ok("Overwritten '" .. s2 .. "'")
          else Logger.error("Failed: " .. (e2 or "?")) end
          _preset_overwrite_name = nil
          reaper.ImGui_CloseCurrentPopup(ctx)
        end
        reaper.ImGui_PopStyleColor(ctx, 4)
        reaper.ImGui_PopStyleVar(ctx, 1)
      end
    end

    if pushed_alpha then reaper.ImGui_PopStyleVar(ctx) end
    reaper.ImGui_EndPopup(ctx)
  end
  popModalStyle()
end


-- ══ Insert / Context / Status ════════════════════════════════


function M.drawPrecisionPanel(ctx)
  local avw     = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  local presets = Cfg.PRECISION_PRESETS
  local cur     = presets[S.precision_preset] or presets[3]
  Widgets.pushComboStyle(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, avw)
  if reaper.ImGui_BeginCombo(ctx, "##prec_combo", "Precision: " .. cur.name) then
    for i, p in ipairs(presets) do
      local sel = (i == S.precision_preset)
      if sel then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
      if reaper.ImGui_Selectable(ctx, p.name .. "##prec" .. i, sel) then
        S.precision_preset = i
      end
      if sel then reaper.ImGui_PopStyleColor(ctx) ; reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    reaper.ImGui_EndCombo(ctx)
  end
  Widgets.popComboStyle(ctx)
end

function M.drawInsertPanel(ctx, dl, ctx_info)
  Widgets.drawInsertPanel(ctx, dl, ctx_info, LFOWrite.generate, LFOWrite.generateAutomationItem)
end

function M.drawContextPanel(ctx, dl, ctx_info)
  Widgets.drawSimpleContextPanel(ctx, dl, ctx_info)
end

function M.drawStatusBar(ctx, dl)
  Widgets.drawStatusBar(ctx, dl)
end

function M.isAdvanced() return _ui_advanced end

function M.drawUIMode(ctx)
  local avw = select(1, reaper.ImGui_GetContentRegionAvail(ctx))
  Widgets.pushComboStyle(ctx)
  reaper.ImGui_SetNextItemWidth(ctx, avw)
  if reaper.ImGui_BeginCombo(ctx, "##uimode2", _ui_advanced and "Mode: Advanced" or "Mode: Standard") then
    local function modeItem(label, is_sel, fn)
      if is_sel then reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Text(), T.hx("#FFFFFF")) end
      if reaper.ImGui_Selectable(ctx, label, is_sel) then fn() end
      if is_sel then reaper.ImGui_PopStyleColor(ctx) ; reaper.ImGui_SetItemDefaultFocus(ctx) end
    end
    modeItem("Standard – core parameters only", not _ui_advanced, function()
      _ui_advanced = false ; reaper.SetExtState("LFOGenerator", "ui_advanced", "0", true)
    end)
    modeItem("Advanced – all parameters", _ui_advanced, function()
      _ui_advanced = true ; reaper.SetExtState("LFOGenerator", "ui_advanced", "1", true)
    end)
    reaper.ImGui_EndCombo(ctx)
  end
  Widgets.popComboStyle(ctx)
end

function M.isCurveVisible() return _ui_advanced end
function M.isAmplitudeVisible() return true end  -- always visible (Standard + Advanced)

return M