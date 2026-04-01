-- ============================================================
--   LFOWrite.lua
--   Both preview and write use VLFO() [0,1] directly.
--   Curve uses sagit*soft_dir. gscale prevents clipping.
--   Final mapping: yv → amp_range → envelope.
-- ============================================================
local M = {}
local Logger     = require("Logger")
local S          = require("LFOState")
local Cfg        = require("LFOConfig")
local Geo        = require("LFOGeometry")
local EnvUtils   = require("EnvelopeUtils")
local EnvConvert = require("EnvConvert")
local GridUtils  = require("GridUtils")
local EnvWriter  = require("EnvWriter")

local PI  = math.pi
local PI2 = math.pi * 2

local toEnvValue      = EnvConvert.toEnvValue
local getGridTimes    = GridUtils.getGridTimes
local getGridDivisions = GridUtils.getGridDivisions
local snapToGrid      = GridUtils.snapToGrid


-- Write one LFO cycle using VLFO values directly.
-- yv = VLFO-based interpolated value [0,1]
-- mapped to amp_range then to envelope.
-- add_wrap: write the closing point at base_t+cdur (default true).
--   Pass false for intermediate cycles to avoid duplicating the next cycle's first point.
local function writeCycle(env, base_t, cdur, conv, lo, hi, mode, amp_lo, amp_hi, rshape, rtension, add_wrap)
  if add_wrap == nil then add_wrap = true end
  local N=S.sides
  local has_curve=S.curve_mode>0 and S.curve_amt~=0
  local is_quant=S.quantize>=2
  -- Always sub-sample when curve is active; quantize is applied LAST after curve
  -- No curve → vertex points only; curve → use S.precision sub-samples per segment
  local prec=Cfg.PRECISION_PRESETS[S.precision_preset] or Cfg.PRECISION_PRESETS[3]
  -- Glitch (mode 5) : forcer Ultra-Precise pour capturer toutes les micro-variations
  if S.curve_mode==5 then prec=Cfg.PRECISION_PRESETS[1] end
  local SUB = has_curve and math.max(4, math.floor(prec.density/20)) or 1
  local sagit=Geo.CurveSagitteScale(N)
  local gscale=(SUB>1) and Geo.computeCurveScale() or 1.0

  local function write_pt(t_abs, yv, shape, tension)
    local v_ar=amp_lo+yv*(amp_hi-amp_lo)
    reaper.InsertEnvelopePointEx(env,-1, t_abs, toEnvValue(v_ar,conv,lo,hi,mode), shape, tension, false, true)
  end

  -- Sort vertices by VTX time, anchored so vertex 0 is always at t=0
  local t0=Geo.VTX(0)
  local sorted_verts={}
  for i=0,N-1 do sorted_verts[#sorted_verts+1]={idx=i, t=(Geo.VTX(i)-t0)%1.0} end
  table.sort(sorted_verts, function(a,b)
    if math.abs(a.t-b.t)<1e-9 then return a.idx<b.idx end  -- stable: tiebreak par index polygone
    return a.t<b.t
  end)

  local all_pts={}
  for si=1,#sorted_verts do
    local i=sorted_verts[si].idx
    local i_next=sorted_verts[si%#sorted_verts+1].idx
    local y1=Geo.VLFO(i); local y2=Geo.VLFO(i_next)
    local t1=sorted_verts[si].t; local t2=sorted_verts[si%#sorted_verts+1].t
    if t2<t1 then t2=1.0 end  -- wrap-around only (strict <)
    if math.abs(t2-t1)<1e-3 then  -- very close or collocated points → no curve
      -- Discontinuity: emit the boundary point without a curve
      all_pts[#all_pts+1]={t=base_t+t1*cdur, y=y1, sh=rshape, tn=rtension}
    elseif SUB>1 then
      for k=0,SUB-1 do
        local t=k/SUB; local xt=t1+(t2-t1)*t
        local yr1=Geo.VRadarY_raw(i); local yr2=Geo.VRadarY_raw(i_next)
        local base_raw=yr1+(yr2-yr1)*Geo.ShapeT(t)
        -- Use actual temporal position so curve direction is correct after flip/reorder
        local angle_t=(t1+(t2-t1)*t+S.phase)*PI2-PI*0.5
        local co=Geo.CurveOff(t,si)
        local y_raw
        if S.curve_mode==4 then
          -- Wavefold uniquement
          local scale = 1.0 + math.abs(co) * 2.0
          y_raw = Geo.wavefold(base_raw * scale)
        else
          -- Standard + Glitch (mode 5) : pipeline standard, hard clamp [-1,1]
          local cv=co*sagit*(-math.sin(angle_t))*gscale
          y_raw=math.max(-1,math.min(1, base_raw+cv))
        end
        local yv=Geo.Quantize(math.max(0,math.min(1, 0.5+(y_raw*S.amp+S.offset)*0.5)))
        all_pts[#all_pts+1]={t=base_t+xt*cdur, y=yv, sh=0, tn=0}
      end
    else
      all_pts[#all_pts+1]={t=base_t+t1*cdur, y=y1, sh=rshape, tn=rtension}
    end
  end
  local lshape=SUB>1 and 0 or rshape; local ltension=SUB>1 and 0 or rtension
  -- Always append the wrap point so shapeFit sees the full cycle; written only when add_wrap=true.
  all_pts[#all_pts+1]={t=base_t+cdur, y=Geo.VLFO(sorted_verts[1].idx), sh=lshape, tn=ltension}
  table.sort(all_pts, function(a,b) return a.t<b.t end)
  -- Apply shapeFit when curve active (minimum points with morpher algorithm)
  if has_curve and #all_pts>2 then
    local prec2=Cfg.PRECISION_PRESETS[S.precision_preset] or Cfg.PRECISION_PRESETS[3]
    local samp={}
    for _,pt in ipairs(all_pts) do samp[#samp+1]={tn=(pt.t-base_t)/cdur, v=pt.y} end
    local lv,hv=math.huge,-math.huge
    for _,s in ipairs(samp) do
      if s.v<lv then lv=s.v end; if s.v>hv then hv=s.v end
    end
    local rng=math.max(hv-lv,1e-6)
    local thr=math.max(0.001, rng*(prec2.threshold_pct/100))
    local fitted=Geo.shapeFit(samp, thr)
    local n=  #fitted
    for i,ft in ipairs(fitted) do
      if add_wrap or i < n then
        write_pt(base_t+ft.tn*cdur, ft.v, ft.shape or 0, ft.tension or 0)
      end
    end
  else
    local n=#all_pts
    for i,p in ipairs(all_pts) do
      if add_wrap or i < n then
        write_pt(p.t, p.y, p.sh, p.tn)
      end
    end
  end
end

function M.generate()
  local env,ts_s,ts_e,time_offset=EnvWriter.resolveTarget()
  if not env then return end
  local conv=EnvUtils.detectConverter(env)
  local lo,hi,mode=EnvUtils.resolveRange(env)
  local range=Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
  local rshape=S.segment_shape; local rtension=(rshape==5) and S.bezier_tension or 0
  if S.cycle_mode=="grid" then
    ts_s=snapToGrid(ts_s); ts_e=snapToGrid(ts_e)
    reaper.GetSet_LoopTimeRange(true,false,ts_s,ts_e,false)
  end
  local dur=ts_e-ts_s; local rel_s=ts_s-(time_offset or 0)
  -- Evaluate 1µs before the region so the anchor never conflicts with the
  -- LFO's first vertex (also at rel_s). Placed outside the delete range so
  -- it survives repeated insertions and always reads the correct pre-LFO value.
  local ANCHOR = 1e-6
  local _,val_at_start = reaper.Envelope_Evaluate(env, rel_s - ANCHOR, 0, 0)
  local _,val_at_end   = reaper.Envelope_Evaluate(env, rel_s+dur, 0, 0)
  reaper.Undo_BeginBlock(); reaper.PreventUIRefresh(1)
  -- Delete range includes rel_s - ANCHOR to clean up any previous anchor point.
  reaper.DeleteEnvelopePointRangeEx(env,-1, rel_s - ANCHOR, rel_s+dur+ANCHOR)
  reaper.InsertEnvelopePointEx(env,-1, rel_s - ANCHOR, val_at_start, 0, 0, false, true)
  if S.cycle_mode=="grid" then
    local divs=getGridDivisions(ts_s,ts_e)
    for di,div in ipairs(divs) do
      local seg_dur=(div.hi-div.lo)*dur
      if seg_dur>0.001 then
        writeCycle(env, rel_s+div.lo*dur, seg_dur, conv,lo,hi,mode, range.lo,range.hi, rshape,rtension, di==#divs)
      end
    end
    Logger.ok(string.format("✔ Grid: %d cells",#divs))
  else
    local cdur=dur/S.cycles
    for c=0,S.cycles-1 do
      writeCycle(env, rel_s+c*cdur, cdur, conv,lo,hi,mode, range.lo,range.hi, rshape,rtension, c==S.cycles-1)
    end
    Logger.ok(string.format("✔ %d cycles × %d vertices",S.cycles,S.sides))
  end
  -- Superposé sur le wrap point du dernier cycle : restaure la valeur d'origine de
  -- l'enveloppe à rel_s+dur pour que la continuité après la région soit préservée.
  reaper.InsertEnvelopePointEx(env,-1, rel_s+dur, val_at_end, 0, 0, false, true)
  reaper.Envelope_SortPointsEx(env,-1)
  reaper.PreventUIRefresh(-1); reaper.UpdateArrange()
  reaper.Undo_EndBlock("Polygon LFO Generator",-1)
end

function M.generateAutomationItem()
  local env,ts_s,ts_e,time_offset=EnvWriter.resolveTarget()
  if not env then return end
  if (time_offset or 0)~=0 then Logger.error("⚠  AI not supported on take FX envelopes"); return end
  local _,en=reaper.GetEnvelopeName(env)
  if en=="Tempo map" then Logger.error("⚠  AI not supported on Tempo track"); return end
  local conv=EnvUtils.detectConverter(env)
  local lo,hi,mode=EnvUtils.resolveRange(env)
  local range=Cfg.AMP_RANGES[S.amp_range] or Cfg.AMP_RANGES[1]
  local rshape=S.segment_shape; local rtension=(rshape==5) and S.bezier_tension or 0
  if S.cycle_mode=="grid" then
    ts_s=snapToGrid(ts_s); ts_e=snapToGrid(ts_e)
    reaper.GetSet_LoopTimeRange(true,false,ts_s,ts_e,false)
  end
  local dur=ts_e-ts_s
  reaper.Undo_BeginBlock(); reaper.PreventUIRefresh(1)
  if S.cycle_mode=="grid" then
    local divs=getGridDivisions(ts_s,ts_e)
    for di,div in ipairs(divs) do
      local seg_dur=(div.hi-div.lo)*dur
      if seg_dur>0.001 then
        writeCycle(env, ts_s+div.lo*dur, seg_dur, conv,lo,hi,mode, range.lo,range.hi, rshape,rtension, di==#divs)
      end
    end
  else
    local cdur=dur/S.cycles
    for c=0,S.cycles-1 do
      writeCycle(env, ts_s+c*cdur, cdur, conv,lo,hi,mode, range.lo,range.hi, rshape,rtension, c==S.cycles-1)
    end
  end
  local ai_idx=EnvWriter.finalizeAutomationItem(env, ts_s, ts_e)
  reaper.PreventUIRefresh(-1); reaper.UpdateArrange()
  reaper.Undo_EndBlock("Polygon LFO Generator – AI",-1)
  if ai_idx>=0 then Logger.ok("✔ Automation item inserted")
  else Logger.error("⚠  InsertAutomationItem failed") end
end

return M