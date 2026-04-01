-- ============================================================
--   SCULPTWrite.lua
--   Context detection, reference capture, and all REAPER write
--   operations for the SCULPT tool.
--
--   Fixes in this version:
--   • Multi-track: scans ALL tracks for selected AIs.
--   • ref_entries: list of {env, ai_idx, pts, conv, lo, hi, mode}
--     so each context keeps its own ScaleConverter.
--   • H compress clamped to 0.999 to prevent point collapse.
--   • Auto-select intermediate points when capturing main-env
--     selection (fills gaps between first/last selected points).
--   • Invert Time already negates Bezier tension for true symmetry.
-- ============================================================

local M = {}

local r            = reaper
local S            = require("SCULPTState")
local SCULPTEngine = require("SCULPTEngine")
local Logger       = require("Logger")
local EnvUtils     = require("EnvelopeUtils")
local EnvConvert   = require("EnvConvert")

-- ── REAPER point wrappers ─────────────────────────────────────

local AI_FLAG = 0x10000000
local function pool_ai(ai)
  return (ai and ai >= 0) and (ai | AI_FLAG) or (ai or -1)
end

local function count_pts(env, ai) return r.CountEnvelopePointsEx(env, pool_ai(ai)) end
local function get_pt(env, ai, i)  return r.GetEnvelopePointEx(env, pool_ai(ai), i) end
local function set_pt(env, ai, i, t, v, sh, tn, sel)
  return r.SetEnvelopePointEx(env, pool_ai(ai), i, t, v, sh, tn, sel)
end
local function ins_pt(env, ai, t, v, sh, tn, sel)
  return r.InsertEnvelopePointEx(env, pool_ai(ai), t, v, sh, tn, sel, true)
end
local function del_pt(env, ai, i) return r.DeleteEnvelopePointEx(env, pool_ai(ai), i) end
local function sort_pts(env, ai)  return r.Envelope_SortPointsEx(env, pool_ai(ai)) end

-- ── Value conversion (via CommonFunction/EnvConvert) ────────
local toEnvValue   = EnvConvert.toEnvValue
local fromEnvValue = EnvConvert.fromEnvValue

local function makeEntryConverter(env)
  local conv        = EnvUtils.detectConverter(env)
  local lo, hi, mode = EnvUtils.resolveRange(env)
  return conv, lo, hi, mode
end

-- Global converter cache for single-env operations (getContexts path)
local function cacheConverter(env)
  local conv, lo, hi, mode = makeEntryConverter(env)
  S.ref_conv = conv
  S.ref_lo   = lo
  S.ref_hi   = hi
  S.ref_mode = mode
end

-- ── Time selection ────────────────────────────────────────────

local function get_ts()
  local ts, te = r.GetSet_LoopTimeRange(false, false, 0, 0, false)
  return ts, te, (te - ts > 0.0001)
end

-- ── Multi-track AI scan ───────────────────────────────────────
-- Returns the pool-time bounds [t0, t1] covered by an automation item.
-- t0 = D_STARTOFFS, t1 = D_STARTOFFS + D_LENGTH * D_RATE
-- This is the range of pool content that maps to the visual AI.
local function getAIPoolBounds(env, ai_idx)
  local startoffs = r.GetSetAutomationItemInfo(env, ai_idx, "D_STARTOFFS", 0, false) or 0
  local length    = r.GetSetAutomationItemInfo(env, ai_idx, "D_LENGTH",    0, false) or 0
  local rate      = r.GetSetAutomationItemInfo(env, ai_idx, "D_RATE",      0, false) or 1
  return startoffs, startoffs + length * math.max(rate, 0.001)
end

-- Returns a list of {env, ai_idx} for every selected AI across all tracks.
local function getAllSelectedAIs()
  local results = {}
  for ti = 0, r.CountTracks(0) - 1 do
    local track = r.GetTrack(0, ti)
    for ei = 0, r.CountTrackEnvelopes(track) - 1 do
      local env = r.GetTrackEnvelope(track, ei)
      for ai = 0, r.CountAutomationItems(env) - 1 do
        if r.GetSetAutomationItemInfo(env, ai, "D_UISEL", 0, false) > 0 then
          results[#results+1] = {env=env, ai_idx=ai}
        end
      end
    end
  end
  return results
end

-- ── getContexts ───────────────────────────────────────────────
-- Returns (env, contexts, multi_ais):
--   env      = selected envelope (primary)
--   contexts = list of ai_idx for that env (-1 = main env)
--   multi_ais = getAllSelectedAIs() for multi-track operations
function M.getContexts()
  local env = r.GetSelectedEnvelope(0)
  local ts, te, has_ts = get_ts()
  local multi_ais = getAllSelectedAIs()

  -- Multi-track: if AIs are selected on multiple envs, return nil/nil to
  -- signal "use multi_ais directly"
  if #multi_ais > 0 then
    -- Check if all AIs belong to the same env
    local same_env = true
    for _, ma in ipairs(multi_ais) do
      if ma.env ~= multi_ais[1].env then same_env = false ; break end
    end
    if not same_env then
      return nil, nil, multi_ais
    end
    -- Single env with AIs
    local contexts = {}
    for _, ma in ipairs(multi_ais) do contexts[#contexts+1] = ma.ai_idx end
    return multi_ais[1].env, contexts, multi_ais
  end

  if not env then return nil, nil, {} end

  if has_ts then
    local ais_in_ts = {}
    for i = 0, r.CountAutomationItems(env) - 1 do
      local pos = r.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
      local len = r.GetSetAutomationItemInfo(env, i, "D_LENGTH",   0, false)
      if pos < te - 0.001 and (pos + len) > ts + 0.001 then
        ais_in_ts[#ais_in_ts+1] = i
      end
    end
    if #ais_in_ts > 0 then return env, ais_in_ts, {} end
    return env, {-1}, {}
  end

  return env, {-1}, {}
end

-- ── Working points (single-env operations) ───────────────────
local function getWorkingPts(env, ai_idx)
  local conv, lo, hi, mode = makeEntryConverter(env)
  local pts = {}
  if ai_idx >= 0 then
    local n = count_pts(env, ai_idx)
    for i = 0, n - 1 do
      local ok, t, v, sh, tn = get_pt(env, ai_idx, i)
      if ok then
        pts[#pts+1] = { idx=i, t=t, v=v,
          vn=fromEnvValue(v,conv,lo,hi,mode), shape=sh, tension=tn }
      end
    end
  else
    local ts, te, has_ts = get_ts()
    local n = r.CountEnvelopePointsEx(env, -1)
    for i = 0, n - 1 do
      local ok, t, v, sh, tn, sel = r.GetEnvelopePointEx(env, -1, i)
      if ok then
        local inc = has_ts and (t >= ts - 0.001 and t <= te + 0.001) or sel
        if inc then
          pts[#pts+1] = { idx=i, t=t, v=v,
            vn=fromEnvValue(v,conv,lo,hi,mode), shape=sh, tension=tn }
        end
      end
    end
  end
  return pts
end

-- ── Guard flag: skip updateReferenceState while writing ──────
-- applyModifiers uses delete+reinsert, which changes sel_cnt and
-- would trigger a false reset of all modifier sliders.
local _applying_modifiers = false

-- ── Reference entries ─────────────────────────────────────────
-- S.ref_entries: list of {env, ai_idx, pts, conv, lo, hi, mode}
-- Replaces the old S.ref_pts / S.ref_conv global approach.

local function computeSelId()
  -- Scan all tracks for selected AIs
  local all_ais = getAllSelectedAIs()
  local ai_keys = {}
  for _, ma in ipairs(all_ais) do
    ai_keys[#ai_keys+1] = tostring(ma.env)..":"..ma.ai_idx
  end
  table.sort(ai_keys)

  -- Always count selected points on the focused envelope regardless of AIs.
  -- This ensures: (1) take/FX envelope focus changes are detected, and
  -- (2) explicitly selected points on the focused env override AIs on other lanes.
  local env = r.GetSelectedEnvelope(0)
  local sel_cnt = 0
  if env then
    local n = r.CountEnvelopePointsEx(env, -1)
    for i = 0, n - 1 do
      local ok, _, _, _, _, sel = r.GetEnvelopePointEx(env, -1, i)
      if ok and sel then sel_cnt = sel_cnt + 1 end
    end
  end

  local ts, te, has_ts = get_ts()
  return tostring(env or "")
    .. "|" .. table.concat(ai_keys, "|")
    .. "|sel:" .. sel_cnt
    .. "|ts:"  .. (has_ts and string.format("%.4f-%.4f", ts, te) or "no")
end

-- Build ref entry for one (env, ai_idx).
-- For main env (ai_idx=-1): auto-expands to include ALL points between
-- first and last selected point (prevents gap-delete glitches).
-- Returns (pts, ai_t0, ai_t1).
-- ai_t0/ai_t1 are the pool-time bounds of the AI (nil for main envelope).
local function buildEntry(env, ai_idx, conv, lo, hi, mode)
  local pl = {}

  if ai_idx >= 0 then
    -- AI: take all pool points
    local n = r.CountEnvelopePointsEx(env, pool_ai(ai_idx))
    for i = 0, n - 1 do
      local ok, t, v, sh, tn = r.GetEnvelopePointEx(env, pool_ai(ai_idx), i)
      if ok then
        pl[#pl+1] = { idx=i, t=t, v=v,
          vn=fromEnvValue(v,conv,lo,hi,mode),
          shape=sh, tension=tn, orig_shape=sh, orig_tension=tn }
      end
    end
    return pl
  else
    -- Main envelope: find first/last selected, then include ALL points in range
    local ts, te, has_ts = get_ts()
    local n = r.CountEnvelopePointsEx(env, -1)
    local t_sel_first, t_sel_last

    for i = 0, n - 1 do
      local ok, t, _, _, _, sel = r.GetEnvelopePointEx(env, -1, i)
      if ok and sel then
        if not t_sel_first or t < t_sel_first then t_sel_first = t end
        if not t_sel_last  or t > t_sel_last  then t_sel_last  = t end
      end
    end

    if has_ts then
      -- Time-selection mode: range is [ts, te]
      for i = 0, n - 1 do
        local ok, t, v, sh, tn = r.GetEnvelopePointEx(env, -1, i)
        if ok and t >= ts - 0.001 and t <= te + 0.001 then
          pl[#pl+1] = { idx=i, t=t, v=v,
            vn=fromEnvValue(v,conv,lo,hi,mode),
            shape=sh, tension=tn, orig_shape=sh, orig_tension=tn }
        end
      end
    elseif t_sel_first then
      -- Point-selection mode: AUTO-EXPAND to include all points in [first,last]
      -- This prevents intermediate unselected points from being deleted.
      for i = 0, n - 1 do
        local ok, t, v, sh, tn = r.GetEnvelopePointEx(env, -1, i)
        if ok and t >= t_sel_first - 1e-6 and t <= t_sel_last + 1e-6 then
          pl[#pl+1] = { idx=i, t=t, v=v,
            vn=fromEnvValue(v,conv,lo,hi,mode),
            shape=sh, tension=tn, orig_shape=sh, orig_tension=tn }
        end
      end
    end
  end
  return pl
end

-- Called every frame. Re-captures when selection changes.
-- Skipped while applyModifiers is writing to avoid sel_cnt drift.
function M.updateReferenceState()
  if _applying_modifiers then return end
  local current_id = computeSelId()
  if current_id == S.ref_sel_id then return end

  S.resetModifiers()
  S.ref_sel_id = current_id
  S.ref_entries = {}

  local all_ais = getAllSelectedAIs()
  local env     = r.GetSelectedEnvelope(0)
  local ts, te, has_ts = get_ts()

  -- Single global converter (for backward compat with editPts)
  if env then cacheConverter(env) end

  -- Check if the focused envelope has explicitly selected points.
  -- When true, those points take priority over AI items on other lanes.
  local env_has_sel_pts = false
  if env then
    local n = r.CountEnvelopePointsEx(env, -1)
    for i = 0, n - 1 do
      local ok, _, _, _, _, sel = r.GetEnvelopePointEx(env, -1, i)
      if ok and sel then env_has_sel_pts = true ; break end
    end
  end

  if env and env_has_sel_pts then
    -- Focused envelope has selected points: use those, ignore AIs on other lanes
    local conv, lo, hi, mode = makeEntryConverter(env)
    local pl = buildEntry(env, -1, conv, lo, hi, mode)
    if #pl > 0 then
      S.ref_entries[#S.ref_entries+1] = {
        env=env, ai_idx=-1, pts=pl,
        conv=conv, lo=lo, hi=hi, mode=mode }
    end
  elseif #all_ais > 0 then
    -- Multi-track or single-track AI path
    for _, ma in ipairs(all_ais) do
      local conv, lo, hi, mode = makeEntryConverter(ma.env)
      local pl = buildEntry(ma.env, ma.ai_idx, conv, lo, hi, mode)
      if #pl > 0 then
        S.ref_entries[#S.ref_entries+1] = {
          env=ma.env, ai_idx=ma.ai_idx, pts=pl,
          conv=conv, lo=lo, hi=hi, mode=mode }
      end
    end
  elseif env then
    -- Main envelope path: time-selection or selected points
    local conv, lo, hi, mode = makeEntryConverter(env)
    local pl = buildEntry(env, -1, conv, lo, hi, mode)
    if #pl > 0 then
      S.ref_entries[#S.ref_entries+1] = {
        env=env, ai_idx=-1, pts=pl,
        conv=conv, lo=lo, hi=hi, mode=mode }
    end

    -- Also capture AIs in TS if present
    if has_ts then
      for i = 0, r.CountAutomationItems(env) - 1 do
        local pos = r.GetSetAutomationItemInfo(env, i, "D_POSITION", 0, false)
        local len = r.GetSetAutomationItemInfo(env, i, "D_LENGTH",   0, false)
        if pos < te and (pos + len) > ts then
          local pl2 = buildEntry(env, i, conv, lo, hi, mode)
          if #pl2 > 0 then
            S.ref_entries[#S.ref_entries+1] = {
              env=env, ai_idx=i, pts=pl2,
              conv=conv, lo=lo, hi=hi, mode=mode }
          end
        end
      end
    end
  end

  -- Keep ref_pts for backward compat (legacy code paths)
  S.ref_pts = (#S.ref_entries > 0) and {} or nil
  if S.ref_pts then
    for _, e in ipairs(S.ref_entries) do
      if e.env == env then S.ref_pts[e.ai_idx] = e.pts end
    end
  end
end

-- ── Timing-safe point writer ──────────────────────────────────
local MIN_PT_GAP = 0.0001

local function safeWritePoints(env, ai_idx, out_list, orig_t_first, orig_t_last, conv, lo, hi, mode)
  if #out_list == 0 then return out_list end

  table.sort(out_list, function(a, b) return a.t < b.t end)

  -- Forward gap enforcement
  for i = 2, #out_list do
    local min_t = out_list[i-1].t + MIN_PT_GAP
    if out_list[i].t < min_t then out_list[i].t = min_t end
  end

  local del_lo = math.min(orig_t_first, out_list[1].t)           - 0.0005
  local del_hi = math.max(orig_t_last,  out_list[#out_list].t)   + 0.0005
  r.DeleteEnvelopePointRangeEx(env, pool_ai(ai_idx), del_lo, del_hi)

  for _, op in ipairs(out_list) do
    local v_raw = toEnvValue(op.vn, conv, lo, hi, mode)
    ins_pt(env, ai_idx, op.t, v_raw, op.shape, op.tension, true)
  end
  sort_pts(env, ai_idx)
  return out_list
end

-- ── Apply modifiers ───────────────────────────────────────────
function M.applyModifiers(env_hint)
  if not S.ref_entries or #S.ref_entries == 0 then return end

  _applying_modifiers = true
  r.PreventUIRefresh(1)
  for _, entry in ipairs(S.ref_entries) do
    local pts = entry.pts
    if #pts > 0 then
      local t_first, t_last = pts[1].t, pts[#pts].t
      for _, p in ipairs(pts) do
        if p.t < t_first then t_first = p.t end
        if p.t > t_last  then t_last  = p.t end
      end

      -- For AIs: extend t_last so the transform range equals the AI's full
      -- visual span in pool-time (D_LENGTH × D_RATE).  This makes pivot/anchor
      -- parameters map correctly when D_RATE ~= 1 (playrate-stretched AIs).
      -- t_first stays anchored at the actual first point to avoid collapsing
      -- points that precede D_STARTOFFS.
      if entry.ai_idx >= 0 then
        local ai_t0, ai_t1 = getAIPoolBounds(entry.env, entry.ai_idx)
        local ai_range = ai_t1 - ai_t0
        if ai_range > 0.001 then
          t_last = math.max(t_last, t_first + ai_range)
        end
      end

      local result = SCULPTEngine.computeTransforms(pts, t_first, t_last)
      local out = {}
      for k, p in ipairs(pts) do
        out[k] = { t=result[k].t, vn=result[k].vn, shape=p.shape, tension=p.tension }
      end
      safeWritePoints(entry.env, entry.ai_idx, out, t_first, t_last,
        entry.conv, entry.lo, entry.hi, entry.mode)
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  _applying_modifiers = false
  -- Re-snapshot the selection id AFTER the write so the next frame
  -- does not see a drift and trigger a false reset.
  S.ref_sel_id = computeSelId()
end

-- ── Apply shape live ──────────────────────────────────────────
function M.applyShapeLive(env_hint)
  if not S.ref_entries or #S.ref_entries == 0 then return end

  _applying_modifiers = true
  r.PreventUIRefresh(1)
  for _, entry in ipairs(S.ref_entries) do
    local pts = entry.pts
    if #pts > 0 then
      local t_first, t_last = pts[1].t, pts[#pts].t
      for _, p in ipairs(pts) do
        if p.t < t_first then t_first = p.t end
        if p.t > t_last  then t_last  = p.t end
      end

      if entry.ai_idx >= 0 then
        local ai_t0, ai_t1 = getAIPoolBounds(entry.env, entry.ai_idx)
        local ai_range = ai_t1 - ai_t0
        if ai_range > 0.001 then
          t_last = math.max(t_last, t_first + ai_range)
        end
      end

      -- Re-read current points from REAPER (post-modifier positions)
      local n = count_pts(entry.env, entry.ai_idx)
      local current = {}
      for i = 0, n - 1 do
        local ok, ct, cv = get_pt(entry.env, entry.ai_idx, i)
        if ok and ct >= t_first - 0.01 and ct <= t_last + 0.01 then
          current[#current+1] = {t=ct, v=cv}
        end
      end
      if #current == 0 then goto continue_slive end

      local out = {}
      for k, cp in ipairs(current) do
        local is_last_main = (entry.ai_idx == -1 and k == #current)
        local sh = is_last_main and 0   or S.point_type
        local tn = is_last_main and 0.0 or S.tension
        out[k] = {
          t = cp.t,
          vn = fromEnvValue(cp.v, entry.conv, entry.lo, entry.hi, entry.mode),
          shape=sh, tension=tn,
        }
      end
      -- Sync ref_pts shape
      for k, p in ipairs(pts) do
        if k <= #out then p.shape=out[k].shape ; p.tension=out[k].tension end
      end
      safeWritePoints(entry.env, entry.ai_idx, out, t_first, t_last,
        entry.conv, entry.lo, entry.hi, entry.mode)
      ::continue_slive::
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  _applying_modifiers = false
  S.ref_sel_id = computeSelId()
end

-- ── Restore original shapes ───────────────────────────────────
function M.doRestoreShapes()
  if not S.ref_entries or #S.ref_entries == 0 then
    Logger.error("  No points captured") ; return
  end
  _applying_modifiers = true
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local total = 0
  for _, entry in ipairs(S.ref_entries) do
    local pts = entry.pts
    local t_first, t_last = pts[1].t, pts[#pts].t
    for _, p in ipairs(pts) do
      if p.t < t_first then t_first = p.t end
      if p.t > t_last  then t_last  = p.t end
    end
    local out = {}
    for _, p in ipairs(pts) do
      out[#out+1] = { t=p.t, vn=p.vn, shape=p.orig_shape, tension=p.orig_tension }
      p.shape=p.orig_shape ; p.tension=p.orig_tension
    end
    total = total + #out
    safeWritePoints(entry.env, entry.ai_idx, out, t_first, t_last,
      entry.conv, entry.lo, entry.hi, entry.mode)
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Restore Original Shapes", -1)
  _applying_modifiers = false
  Logger.ok(string.format("✔ Original shapes restored  (%d pts)", total))
end

-- ── Restore original shape type only ─────────────────────────
-- Resets interpolation type (shape + tension) of each captured point
-- back to its original value, WITHOUT touching positions or values.
-- Safe to call after amplitude/timing modifier sliders have been moved.
function M.doRestoreShapeTypeOnly(env)
  if not S.ref_entries or #S.ref_entries == 0 then
    Logger.error("  No points captured") ; return
  end
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local total = 0
  for _, entry in ipairs(S.ref_entries) do
    local live_env    = entry.env
    local live_ai_idx = pool_ai(entry.ai_idx)
    for _, p in ipairs(entry.pts) do
      -- Read current live t and v (may differ from ref due to modifiers)
      local ok, t_live, v_live = r.GetEnvelopePointEx(live_env, live_ai_idx, p.idx)
      if ok then
        r.SetEnvelopePointEx(live_env, live_ai_idx, p.idx,
          t_live, v_live, p.orig_shape, p.orig_tension, nil)
        -- Update working shape in ref so further operations stay consistent
        p.shape   = p.orig_shape
        p.tension = p.orig_tension
        total = total + 1
      end
    end
    r.Envelope_SortPointsEx(live_env, live_ai_idx)
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock("Restore Original Shape Type", -1)
  Logger.ok(string.format("✔ Shape type restored  (%d pts)", total))
end

-- ── Commit undo ───────────────────────────────────────────────
function M.commitUndo(label)
  r.Undo_BeginBlock()
  r.Undo_EndBlock(label, -1)
end

-- ── Helper for single-env actions ────────────────────────────
local function resetRef()
  S.ref_entries = {}
  S.ref_pts     = nil
  S.ref_sel_id  = ""
end

-- editPts: for operations (rnd, mirror, invert) — single env, any context
local function editPts(label, fn)
  local env, contexts, multi_ais = M.getContexts()

  -- Multi-track: operate on each env separately
  if not env and #multi_ais > 0 then
    r.Undo_BeginBlock()
    r.PreventUIRefresh(1)
    local total = 0
    for _, ma in ipairs(multi_ais) do
      local conv, lo, hi, mode = makeEntryConverter(ma.env)
      local pts = getWorkingPts(ma.env, ma.ai_idx)
      if #pts > 0 then
        total = total + #pts
        local t_first, t_last = pts[1].t, pts[#pts].t
        local out = {}
        for k, p in ipairs(pts) do
          local nv, nt, ns, ntn = fn(pts, k, ma.ai_idx)
          out[k] = {
            t       = (nt  ~= nil) and nt  or p.t,
            vn      = (nv  ~= nil) and nv  or p.vn,
            shape   = (ns  ~= nil) and ns  or p.shape,
            tension = (ntn ~= nil) and ntn or p.tension,
          }
        end
        safeWritePoints(ma.env, ma.ai_idx, out, t_first, t_last, conv, lo, hi, mode)
      end
    end
    r.PreventUIRefresh(-1)
    r.UpdateArrange()
    r.Undo_EndBlock(label, -1)
    resetRef()
    Logger.ok(string.format("✔ %s  (%d pts)", label, total))
    return
  end

  if not env or not contexts then
    Logger.error("  No points selected / time selection") ; return
  end
  cacheConverter(env)
  r.Undo_BeginBlock()
  r.PreventUIRefresh(1)
  local total = 0
  for _, ai_idx in ipairs(contexts) do
    local pts = getWorkingPts(env, ai_idx)
    if #pts > 0 then
      total = total + #pts
      local t_first, t_last = pts[1].t, pts[#pts].t
      local out = {}
      for k, p in ipairs(pts) do
        local nv, nt, ns, ntn = fn(pts, k, ai_idx)
        out[k] = {
          t       = (nt  ~= nil) and nt  or p.t,
          vn      = (nv  ~= nil) and nv  or p.vn,
          shape   = (ns  ~= nil) and ns  or p.shape,
          tension = (ntn ~= nil) and ntn or p.tension,
        }
      end
      safeWritePoints(env, ai_idx, out, t_first, t_last,
        S.ref_conv, S.ref_lo, S.ref_hi, S.ref_mode)
    end
  end
  r.PreventUIRefresh(-1)
  r.UpdateArrange()
  r.Undo_EndBlock(label, -1)
  resetRef()
  Logger.ok(string.format("✔ %s  (%d pts)", label, total))
end

-- ── Re-export RANGES for backward compat ─────────────────────
-- SCULPTPanel accesses Logic.RANGES; expose it from SCULPTConfig here.
M.RANGES = require("SCULPTConfig").RANGES

-- ── Public actions ────────────────────────────────────────────

function M.doRndValues()
  local rt = M.RANGES[S.range_type]
  editPts("Random Values", function(pts, k)
    if not S.rnd_edges and (k == 1 or k == #pts) then return pts[k].vn end
    return math.max(0, math.min(1, rt.lo + math.random() * (rt.hi - rt.lo)))
  end)
end

function M.doMirrorAmp()
  editPts("Mirror Amplitude", function(pts, k)
    if not S.rnd_edges and (k == 1 or k == #pts) then return pts[k].vn end
    return 1.0 - pts[k].vn
  end)
end

function M.doRndShape()
  local env, contexts, multi_ais = M.getContexts()
  local SHAPES = {0, 1, 2, 3, 4, 5}

  local function applyRnd(tgt_env, ai_idx, pts)
    local conv, lo, hi, mode = makeEntryConverter(tgt_env)
    r.PreventUIRefresh(1)
    for k, p in ipairs(pts) do
      local is_last_main = (ai_idx == -1 and k == #pts)
      local sh, tn
      if is_last_main then sh, tn = 0, 0.0
      else
        sh = SHAPES[math.random(#SHAPES)]
        tn = (sh == 5) and (math.random() * 2 - 1) or 0.0
      end
      local v_raw = toEnvValue(p.vn, conv, lo, hi, mode)
      set_pt(tgt_env, ai_idx, p.idx, p.t, v_raw, sh, tn, true)
      -- Sync ref_entries shape
      if S.ref_entries then
        for _, e in ipairs(S.ref_entries) do
          if e.env == tgt_env and e.ai_idx == ai_idx then
            for _, rp in ipairs(e.pts) do
              if rp.idx == p.idx then rp.shape=sh ; rp.tension=tn ; break end
            end
          end
        end
      end
    end
    sort_pts(tgt_env, ai_idx)
    r.PreventUIRefresh(-1)
  end

  r.Undo_BeginBlock()
  local total = 0
  if not env and #multi_ais > 0 then
    for _, ma in ipairs(multi_ais) do
      local pts = getWorkingPts(ma.env, ma.ai_idx)
      if #pts > 0 then applyRnd(ma.env, ma.ai_idx, pts) ; total=total+#pts end
    end
  elseif env and contexts then
    cacheConverter(env)
    for _, ai_idx in ipairs(contexts) do
      local pts = getWorkingPts(env, ai_idx)
      if #pts > 0 then applyRnd(env, ai_idx, pts) ; total=total+#pts end
    end
  end
  r.UpdateArrange()
  r.Undo_EndBlock("Random Shape", -1)
  Logger.ok(string.format("✔ Random Shape  (%d pts)", total))
end

function M.doInvertTime()
  -- Bezier tension is negated for true mirror symmetry.
  -- Fast+/Fast- are swapped.
  editPts("Invert Time", function(pts, k)
    local tf, tl = pts[1].t, pts[#pts].t
    local src  = pts[k]
    local prev = (k > 1) and pts[k-1] or nil
    local n_sh, n_tn = 0, 0.0
    if prev then
      if     prev.shape == 3 then n_sh=4 ; n_tn=-prev.tension
      elseif prev.shape == 4 then n_sh=3 ; n_tn=-prev.tension
      elseif prev.shape == 5 then n_sh=5 ; n_tn=-prev.tension
      else                        n_sh=prev.shape ; n_tn=prev.tension
      end
    end
    local new_sh = (k == 1) and 0 or n_sh
    local new_tn = (k == 1) and 0.0 or n_tn
    return src.vn, tf + tl - src.t, new_sh, new_tn
  end)
end

function M.doRndPos()
  local env, contexts, multi_ais = M.getContexts()
  local rt = M.RANGES[S.range_type]

  local function doShuffle(tgt_env, ai_idx)
    local conv, lo, hi, mode = makeEntryConverter(tgt_env)
    local pts = getWorkingPts(tgt_env, ai_idx)
    if #pts < 3 then return 0 end
    local tf, tl = pts[1].t, pts[#pts].t
    local span   = tl - tf
    local inner  = {}
    for k = 2, #pts-1 do
      inner[#inner+1] = {vn=pts[k].vn, shape=pts[k].shape, tension=pts[k].tension}
    end
    for i = #inner, 2, -1 do
      local j = math.random(i) ; inner[i], inner[j] = inner[j], inner[i]
    end
    local ntimes = {}
    for i = 1, #inner do ntimes[i] = tf + math.random() * span end
    table.sort(ntimes)
    local vf = S.rnd_edges and (rt.lo+math.random()*(rt.hi-rt.lo)) or pts[1].vn
    local vl = S.rnd_edges and (rt.lo+math.random()*(rt.hi-rt.lo)) or pts[#pts].vn
    local out = {{t=tf, vn=vf, shape=pts[1].shape, tension=pts[1].tension}}
    for i, t in ipairs(ntimes) do
      out[#out+1] = {t=t, vn=inner[i].vn, shape=inner[i].shape, tension=inner[i].tension}
    end
    out[#out+1] = {t=tl, vn=vl, shape=pts[#pts].shape, tension=pts[#pts].tension}
    safeWritePoints(tgt_env, ai_idx, out, tf, tl, conv, lo, hi, mode)
    return #pts
  end

  r.Undo_BeginBlock() ; r.PreventUIRefresh(1)
  local total = 0
  if not env and #multi_ais > 0 then
    for _, ma in ipairs(multi_ais) do total=total+doShuffle(ma.env, ma.ai_idx) end
  elseif env and contexts then
    cacheConverter(env)
    for _, ai_idx in ipairs(contexts) do total=total+doShuffle(env, ai_idx) end
  else
    r.PreventUIRefresh(-1) ; r.Undo_EndBlock("Random Positions",-1)
    Logger.error("  No points selected / time selection") ; return
  end
  r.PreventUIRefresh(-1) ; r.UpdateArrange() ; r.Undo_EndBlock("Random Positions",-1)
  resetRef()
  Logger.ok(string.format("✔ Random Positions  (%d pts)", total))
end

function M.doRndAll()
  local env, contexts, multi_ais = M.getContexts()
  local rt     = M.RANGES[S.range_type]
  local SHAPES = {0, 1, 2, 3, 4, 5}
  local function rsh() local s=SHAPES[math.random(#SHAPES)]; return s,(s==5) and (math.random()*2-1) or 0.0 end

  local function doAll(tgt_env, ai_idx)
    local conv, lo, hi, mode = makeEntryConverter(tgt_env)
    local pts = getWorkingPts(tgt_env, ai_idx)
    if #pts < 3 then return 0 end
    local tf, tl = pts[1].t, pts[#pts].t
    local span   = tl - tf
    local ntimes = {}
    for i = 1, #pts-2 do ntimes[i]=tf+math.random()*span end
    table.sort(ntimes)
    local vf = S.rnd_edges and (rt.lo+math.random()*(rt.hi-rt.lo)) or pts[1].vn
    local vl = S.rnd_edges and (rt.lo+math.random()*(rt.hi-rt.lo)) or pts[#pts].vn
    local sh, tn = rsh()
    local out = {{t=tf, vn=vf, shape=sh, tension=tn}}
    for _, t in ipairs(ntimes) do
      sh, tn = rsh()
      out[#out+1] = {t=t, vn=rt.lo+math.random()*(rt.hi-rt.lo), shape=sh, tension=tn}
    end
    sh, tn = rsh()
    out[#out+1] = {t=tl, vn=vl, shape=sh, tension=tn}
    safeWritePoints(tgt_env, ai_idx, out, tf, tl, conv, lo, hi, mode)
    return #pts
  end

  r.Undo_BeginBlock() ; r.PreventUIRefresh(1)
  local total = 0
  if not env and #multi_ais > 0 then
    for _, ma in ipairs(multi_ais) do total=total+doAll(ma.env, ma.ai_idx) end
  elseif env and contexts then
    for _, ai_idx in ipairs(contexts) do total=total+doAll(env, ai_idx) end
  end
  r.PreventUIRefresh(-1) ; r.UpdateArrange() ; r.Undo_EndBlock("Random All",-1)
  resetRef()
  Logger.ok(string.format("✔ Random All  (%d pts)", total))
end

return M
