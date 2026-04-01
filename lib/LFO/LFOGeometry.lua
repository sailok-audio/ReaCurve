-- ============================================================
--   LFOGeometry.lua
-- ============================================================
local M = {}
local S = require("LFOState")
local PI  = math.pi
local PI2 = math.pi * 2

local function HSV(h,s,v)
  h=h%360; local c=v*s; local x=c*(1-math.abs((h/60)%2-1)); local m=v-c
  local r,g,b
  if h<60 then r,g,b=c,x,0 elseif h<120 then r,g,b=x,c,0
  elseif h<180 then r,g,b=0,c,x elseif h<240 then r,g,b=0,x,c
  elseif h<300 then r,g,b=x,0,c else r,g,b=c,0,x end
  return math.floor((r+m)*255+.5)*16777216+math.floor((g+m)*255+.5)*65536
        +math.floor((b+m)*255+.5)*256+255
end
function M.VColor(i) return HSV((i/S.sides)*360, 0.80, 1.0) end

local function tanh(x) local e1,e2=math.exp(x),math.exp(-x); return (e1-e2)/(e1+e2) end

function M.Warp(t)
  if math.abs(S.warp) < 1e-4 or t<=0 or t>=1 then return t end
  local k=6^math.abs(S.warp)
  return S.warp>0 and t^k or 1-(1-t)^k
end

function M.ShapeT(t)
  local sh=S.segment_shape
  if sh==0 then return t end
  if sh==1 then return t>=1 and 1 or 0 end
  if sh==2 then return t*t*(3-2*t) end
  if sh==3 then return 1-(1-t)^2 end
  if sh==4 then return t*t end
  if sh==5 then
    local ten=S.bezier_tension; local v=math.abs(ten)
    local m1,m2=0.625,0.625
    local h10=t*t*t-2*t*t+t; local h11=t*t*t-t*t; local h01=-2*t*t*t+3*t*t
    local tc_cr=h01+h10*m1+h11*m2
    local p1y=ten>=0 and 0 or v; local p2y=ten>=0 and (1-v) or 1
    local inv_t=1-t
    local tc_b=3*(inv_t^2)*t*p1y+3*inv_t*(t^2)*p2y+t^3
    local tc_p=(ten>=0) and (t^18) or (1-(1-t)^18)
    return tc_cr+(tc_b+(tc_p-tc_b)*v-tc_cr)*(v^0.1)
  end
  return t
end

function M.CurveOff(t, seg)
  if S.curve_mode==0 or S.curve_amt==0 then return 0 end
  local a=S.curve_amt; local cm=S.curve_mode
  if cm==1 then return a*math.sin(t*PI) end
  if cm==2 then return a*math.sin(t*PI)*((seg%2==0) and 1 or -1) end
  if cm==3 then return a*math.sin(t*PI)*math.cos(t*PI2*2) end   -- Wave
  if cm==4 then return a*math.sin(t*PI)*3.0 end               -- Wfold driver
  if cm==5 then
    -- Glitch: amplitude 3.0 is preserved to maintain the impact.
    local abs_a = math.abs(a)
    local rep = 1 + math.floor(abs_a * 7)
    local tf = (t * rep * 2) % 2.0
    if tf > 1.0 then tf = 2.0 - tf end  -- triangle 0 -> 1 -> 0

    if a <= 0 then
      -- Original behavior preserved:
      -- The wave starts from the segment (0) and descends inward (down to -3).
      return a * tf * 3.0
    else
      -- New symmetric behavior for positive a:
      -- Stays inside the radar to avoid clipping.
      -- The wave starts from the "bottom" (-3) and rises toward the segment (0).
      -- This is the exact visual opposite of the negative mode.
      return abs_a * (tf - 1.0) * 3.0
    end
  end
  return 0
end
local function normVtx(v)
  return ((v + 0.5) % 1.0) - 0.5
end

-- Shared helper: mirrors each vertex in polar space.
-- mirror_vis(vis) returns the mirrored visual angle.
local function flipPolar(mirror_vis)
  local N = S.sides
  for i = 0, N - 1 do
    local off   = S.v_offsets[i]
    local vr    = off and off[1] or 0
    local vtx   = off and off[2] or 0
    local vis   = M.Warp(i / N) + S.phase + vtx
    local vis_m = mirror_vis(vis)
    -- Derive the absolute temporal position and normalize to [0, 1)
    local abs_t  = (vis_m - S.phase) % 1.0
    local vtx_new = abs_t - M.Warp(i / N)
    S.v_offsets[i] = { vr, vtx_new }
  end
end

function M.flipH()
  flipPolar(function(v) return 0.5 - v end)
end

function M.flipV()
  flipPolar(function(v) return -v end)
end
-- Wavefold: symmetric triangle fold around 0
-- Positive: x>1 folds back (1.2→0.8, 1.8→0.2, 2.2→-0.2)
-- Negative: x<-1 folds back exactly mirrored (-1.2→-0.8, -2.2→0.2)
-- wavefold(-x) == -wavefold(x) always
function M.wavefold(x)
  -- fold around ±1 using triangle wave
  -- period=4, centered on 0: -2→0→2→0→-2
  -- map to period by folding abs value
  local s = x >= 0 and 1.0 or -1.0
  x = math.abs(x) % 4.0
  -- x in [0,4): triangle: 0→0,1→1,2→0,3→-1,4→0 but we want 0→0,1→1,2→0 then back
  if x <= 1.0 then
    return s * x                   -- [0,1] → same
  elseif x <= 3.0 then
    return s * (2.0 - x)           -- [1,3] → [1,-1]: fold back through 0
  else
    return s * (x - 4.0)           -- [3,4] → [-1,0]
  end
end

function M.CurveSagitteScale(N) return 1.0-math.cos(PI/N) end

function M.SegmentDeviation(t,seg,shape_scale,curve_scale)
  -- Square shape: clamp deviation so it doesn't blow out the radar
  if S.segment_shape==1 then
    return tanh((t-0.5)*20)*shape_scale*0.15 + M.CurveOff(t,seg)*curve_scale
  end
  return (M.ShapeT(t)-t)*shape_scale + M.CurveOff(t,seg)*curve_scale
end

function M.Quantize(y)
  local n=S.quantize; if n<2 then return y end
  return math.floor(y*(n-1)+0.5)/(n-1)
end

function M.VAngle(i) return (M.Warp(i/S.sides)+S.phase)*PI2-PI*0.5 end

function M.VRadarDragged(idx)
  local i=idx%S.sides
  local off=S.v_offsets[i]
  local vr  = off and off[1] or 0
  local vtx = off and off[2] or 0
  local a_i = (M.Warp(i/S.sides)+vtx+S.phase)*PI2-PI*0.5
  local rx,ry = math.cos(a_i), math.sin(a_i)
  if S.align~=0 then
    local a0=M.VAngle(0); local d=math.cos(PI2*i/S.sides)
    local lx,ly=math.cos(a0)*d, math.sin(a0)*d
    rx=rx+(lx-rx)*S.align; ry=ry+(ly-ry)*S.align
  end
  return rx*(1+vr), ry*(1+vr)
end

function M.PathPoint(t)
  t=t%1; if t<0 then t=t+1 end
  local N=S.sides; local seg=math.floor(t*N); local lt=t*N-seg
  local i=seg%N; local j=(i+1)%N
  local rx1,ry1=M.VRadarDragged(i)
  if lt<1e-9 then return rx1,ry1 end
  local rx2,ry2=M.VRadarDragged(j)
  if lt>1-1e-9 then return rx2,ry2 end
  local dx=rx2-rx1; local dy=ry2-ry1; local len=math.sqrt(dx*dx+dy*dy)
  if len<1e-6 then return rx1,ry1 end
  local nx,ny=-dy/len, dx/len
  if nx*(rx1+rx2)*0.5+ny*(ry1+ry2)*0.5<0 then nx,ny=-nx,-ny end
  local dev=M.SegmentDeviation(lt,i+1,len*0.4,M.CurveSagitteScale(N))
  return rx1+dx*lt+nx*dev, ry1+dy*lt+ny*dev
end

function M.VRadarNorm(idx)
  if S.path_slide~=0 then
    return M.PathPoint(((idx%S.sides)/S.sides + S.path_slide)%1)
  end
  return M.VRadarDragged(idx)
end

-- Raw Y in radar space: maps to [-r_i, +r_i]
-- Negative means vertex below center → negative LFO amplitude
function M.VRadarY_raw(i)
  local _,ry=M.VRadarNorm(i%S.sides); return -ry
end

-- VLFO: [0,1] with amp+offset. Used for display and write control points.
function M.VLFO(i)
  return M.Quantize(math.max(0,math.min(1, 0.5+(M.VRadarY_raw(i)*S.amp+S.offset)*0.5)))
end

function M.VTX(i)
  local idx=i%S.sides
  return M.Warp(idx/S.sides)+(S.v_offsets[idx] and S.v_offsets[idx][2] or 0)
end

-- ── Clamping ─────────────────────────────────────────────────
-- Radial: clamp r_i = 1+v_r to [0, 1] (inside unit circle, can be 0 = center)
-- Temporal: absolute [0,1] only, NO ordering constraint
function M.ClampOffsets(i)
  if not S.v_offsets[i] then return end
  -- No radial clamping: user can place points anywhere including below center
  -- v_r < -1 gives r_i < 0 → amplitude is negative
  if i==0 then S.v_offsets[i][2]=0; return end
  local abs_t=M.VTX(i)
  if abs_t<0 then S.v_offsets[i][2]=S.v_offsets[i][2]-abs_t
  elseif abs_t>1 then S.v_offsets[i][2]=S.v_offsets[i][2]-(abs_t-1) end
end

-- ── computeCurveScale ─────────────────────────────────────────
-- Operates in RAW Y space [-1,1] so it's independent of amp/offset.
-- Curve is applied to raw Y, THEN amp+offset are applied.
-- This decouples curve shape from amplitude setting.
function M.computeCurveScale()
  if S.curve_mode==0 or S.curve_amt==0 then return 1.0 end
  if S.curve_mode==4 then return 1.0 end  -- wfold: wavefold handles it
  if S.curve_mode==5 then return 1.0 end  -- glitch: bypass on both sides (symmetric)
  local N=S.sides; local sagit=M.CurveSagitteScale(N); local SUB=32
  local gscale=1.0
  -- Sort by temporal position, matching writeCycle, so angle_t is consistent after flip
  local sorted={}
  for i=0,N-1 do sorted[#sorted+1]={idx=i, t=M.VTX(i)} end
  table.sort(sorted, function(a,b)
    if math.abs(a.t-b.t)<1e-9 then return a.idx<b.idx end
    return a.t<b.t
  end)
  for si=1,N do
    local i=sorted[si].idx
    local i_next=sorted[si%N+1].idx
    local y1=M.VRadarY_raw(i); local y2=M.VRadarY_raw(i_next)
    local t1=M.VTX(i); local t2=M.VTX(i_next)
    if t2<t1 then t2=1.0 end
    for k=0,SUB-1 do
      local t=k/SUB
      local base_raw=y1+(y2-y1)*M.ShapeT(t)
      local angle_t=(t1+(t2-t1)*t+S.phase)*PI2-PI*0.5
      local co=M.CurveOff(t,si)
      local raw_cv = co*sagit*(-math.sin(angle_t))
      if raw_cv>1e-9 then
        local hd=1.0-base_raw
        if hd>=0 and raw_cv*gscale>hd then gscale=hd/raw_cv end
      elseif raw_cv<-1e-9 then
        local hd=1.0+base_raw
        if hd>=0 and (-raw_cv)*gscale>hd then gscale=hd/(-raw_cv) end
      end
    end
  end
  return math.max(0,gscale)
end

-- ── Symmetry operations ───────────────────────────────────────
-- "Flip Amp" (was H-flip): inverts all vertices' amplitude (top↔bottom in LFO)
function M.applyFlipAmp()
  for i=0,S.sides-1 do
    if not S.v_offsets[i] then S.v_offsets[i]={0,0} end
    S.v_offsets[i][1]=-2.0-S.v_offsets[i][1]
    M.ClampOffsets(i)
  end
end

-- "Flip Time" (was V-flip): reverses temporal order of vertices (left↔right mirror)
function M.applyFlipTime()
  local N=S.sides; local snap_vr,snap_t={},{}
  for i=0,N-1 do
    snap_vr[i]=S.v_offsets[i] and S.v_offsets[i][1] or 0
    snap_t[i]=M.VTX(i)
  end
  for i=1,N-1 do
    local j=(N-i)%N
    if not S.v_offsets[i] then S.v_offsets[i]={0,0} end
    S.v_offsets[i][1]=snap_vr[j]
    S.v_offsets[i][2]=(1.0-snap_t[j])-M.Warp(i/N)
  end
  for i=0,N-1 do M.ClampOffsets(i) end
end

-- Sym Time from Left: mirrors left-side vertices (t<0.5) to the right (t>0.5)
-- Right vertices get t_right = 1 - t_left, same amplitude
function M.applySymTimeFromLeft()
  local N=S.sides; local snap_vr,snap_t={},{}
  for i=0,N-1 do
    snap_vr[i]=S.v_offsets[i] and S.v_offsets[i][1] or 0
    snap_t[i]=M.VTX(i)
  end
  -- Find vertices in left half (t < 0.5), mirror to right
  for i=0,N-1 do
    if snap_t[i] < 0.5 then
      -- Find the "mirror" vertex on the right side
      for j=0,N-1 do
        if j~=i and snap_t[j]>=0.5 then
          -- Pick closest right-side vertex
          local t_target=1.0-snap_t[i]
          if math.abs(snap_t[j]-t_target) < 0.01 or j==(N-i)%N then
            if not S.v_offsets[j] then S.v_offsets[j]={0,0} end
            S.v_offsets[j][1]=snap_vr[i]
            S.v_offsets[j][2]=t_target-M.Warp(j/N)
            M.ClampOffsets(j)
            break
          end
        end
      end
    end
  end
end

-- Sym Time from Right: mirrors right-side vertices (t>0.5) to the left (t<0.5)
function M.applySymTimeFromRight()
  local N=S.sides; local snap_vr,snap_t={},{}
  for i=0,N-1 do
    snap_vr[i]=S.v_offsets[i] and S.v_offsets[i][1] or 0
    snap_t[i]=M.VTX(i)
  end
  for i=1,N-1 do
    local j=(N-i)%N
    if snap_t[i]>=0.5 and j>0 then
      if not S.v_offsets[j] then S.v_offsets[j]={0,0} end
      S.v_offsets[j][1]=snap_vr[i]
      S.v_offsets[j][2]=(1.0-snap_t[i])-M.Warp(j/N)
      M.ClampOffsets(j)
    end
  end
end

-- ── shapeFit (from MorphEngine) ──────────────────────────────
-- Reduces dense [{tn,v}] samples to minimal control points.
-- Returns [{tn, v, shape, tension}] with max error ≤ threshold.
local SHAPE_CANDIDATES = {
  { id=0, fn=function(t) return t end },
  { id=2, fn=function(t) return t*t*(3-2*t) end },
  { id=3, fn=function(t) return 2*t-t*t end },
  { id=4, fn=function(t) return t*t end },
}
local function sfSegError(samples, lo_i, hi_i, fn)
  local lo,hi = samples[lo_i], samples[hi_i]
  local span = hi.tn-lo.tn
  if span<1e-12 then return 0 end
  local me=0
  for i=lo_i+1,hi_i-1 do
    local t=(samples[i].tn-lo.tn)/span
    local e=math.abs(samples[i].v-(lo.v+fn(t)*(hi.v-lo.v)))
    if e>me then me=e end
  end
  return me
end
local function sfBestCand(samples, lo_i, hi_i)
  local best,berr=SHAPE_CANDIDATES[1],math.huge
  for _,c in ipairs(SHAPE_CANDIDATES) do
    local e=sfSegError(samples,lo_i,hi_i,c.fn)
    if e<berr then berr=e; best=c end
  end
  return best,berr
end
function M.shapeFit(samples, threshold)
  if #samples<=2 then
    local out={}
    for _,p in ipairs(samples) do out[#out+1]={tn=p.tn,v=p.v,shape=0,tension=0} end
    return out
  end
  local pts={}; local start=1
  while start<#samples do
    local bend,bcand=start+1,SHAPE_CANDIDATES[1]
    for hi=start+1,#samples do
      local cand,err=sfBestCand(samples,start,hi)
      if err<=threshold then bend=hi; bcand=cand else break end
    end
    pts[#pts+1]={idx=start,tn=samples[start].tn,v=samples[start].v,shape=bcand.id,tension=0}
    start=bend
  end
  pts[#pts+1]={idx=#samples,tn=samples[#samples].tn,v=samples[#samples].v,shape=0,tension=0}
  -- Merge pass
  local i=2
  while i<#pts do
    local prev,next=pts[i-1],pts[i+1]
    local cand,err=sfBestCand(samples,prev.idx,next.idx)
    if err<=threshold then table.remove(pts,i); prev.shape=cand.id else i=i+1 end
  end
  local out={}
  for _,p in ipairs(pts) do out[#out+1]={tn=p.tn,v=p.v,shape=p.shape,tension=0} end
  return out
end

return M