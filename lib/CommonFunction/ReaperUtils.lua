-- ============================================================
--   ReaperUtils.lua
--   REAPER API wrappers: AI selection, envelope lookup,
--   selection save/restore, context detection.
--   No morph business logic here.
-- ============================================================

local M = {}

-- ── Envelope access ──────────────────────────────────────────

-- Returns a fresh envelope reference from an ai_obj { track_idx, env_idx }.
function M.getFreshEnv(ai_obj)
  local track = reaper.GetTrack(0, ai_obj.track_idx)
  if not track then return nil end
  return reaper.GetTrackEnvelope(track, ai_obj.env_idx)
end

-- Returns the selected envelope, or the first visible envelope on a fallback track.
function M.getActiveEnvelope(fallback_track)
  local env = reaper.GetSelectedEnvelope(0)
  if env then return env end
  local track = fallback_track or reaper.GetSelectedTrack(0, 0)
  if not track then return nil end
  for ei = 0, reaper.CountTrackEnvelopes(track) - 1 do
    local e = reaper.GetTrackEnvelope(track, ei)
    local h = reaper.GetEnvelopeInfo_Value(e, "I_TCPH")
    if h and h > 0 then return e end
  end
  return nil
end

-- ── Label formatting ─────────────────────────────────────────

-- Builds a short display label: "TRK_N › EnvName  · extra".
function M.formatSlotLabel(tname, ename, extra)
  local t = (tname or ""):gsub("^[Tt]rack%s*", "T"):gsub("^TRACK%s*", "T")
  if #t > 14 then t = t:sub(1, 13) .. "…" end
  local e = ename or ""
  if #e > 18 then e = e:sub(1, 17) .. "…" end
  if extra and extra ~= "" then
    return string.format("%s › %s  · %s", t, e, extra)
  end
  return string.format("%s › %s", t, e)
end

-- ── AI selection ─────────────────────────────────────────────

-- Deselects all automation items in the project.
function M.deselectAllAIs()
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    for ei = 0, reaper.CountTrackEnvelopes(track) - 1 do
      local env = reaper.GetTrackEnvelope(track, ei)
      for ai = 0, reaper.CountAutomationItems(env) - 1 do
        reaper.GetSetAutomationItemInfo(env, ai, "D_UISEL", 0, true)
      end
    end
  end
end

-- Returns the first selected automation item (highest stack index wins),
-- or nil if none is selected.
function M.getSelectedAI()
  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    for ei = 0, reaper.CountTrackEnvelopes(track) - 1 do
      local env      = reaper.GetTrackEnvelope(track, ei)
      local ai_count = reaper.CountAutomationItems(env)
      -- Iterate in reverse to prefer the topmost AI in the stack.
      for ai_idx = ai_count - 1, 0, -1 do
        if reaper.GetSetAutomationItemInfo(env, ai_idx, "D_UISEL", 0, false) > 0 then
          local _, ename  = reaper.GetEnvelopeName(env)
          local track_num = math.floor(reaper.GetMediaTrackInfo_Value(track, "IP_TRACKNUMBER"))
          return {
            track_idx = ti,
            env_idx   = ei,
            ai_idx    = ai_idx,
            pos       = reaper.GetSetAutomationItemInfo(env, ai_idx, "D_POSITION", 0, false),
            len       = reaper.GetSetAutomationItemInfo(env, ai_idx, "D_LENGTH",   0, false),
            pool      = reaper.GetSetAutomationItemInfo(env, ai_idx, "D_POOL_ID",  0, false),
            tname     = "TRK_" .. track_num,
            ename     = ename,
            label     = M.formatSlotLabel("TRK_"..track_num, ename, "AI "..ai_idx),
          }
        end
      end
    end
  end
  return nil
end

-- ── Envelope point selection ─────────────────────────────────

-- Deselects all points on the currently active envelope.
function M.deselectAllEnvPoints()
  local env = reaper.GetSelectedEnvelope(0)
  if not env then
    local track = reaper.GetSelectedTrack(0, 0)
    if track then
      for ei = 0, reaper.CountTrackEnvelopes(track) - 1 do
        local e = reaper.GetTrackEnvelope(track, ei)
        if reaper.GetEnvelopeInfo_Value(e, "I_TCPH") > 0 then
          env = e ; break
        end
      end
    end
  end
  if not env then return end
  local n       = reaper.CountEnvelopePointsEx(env, -1)
  local changed = false
  for i = 0, n - 1 do
    local ok, t, v, sh, tn_val, sel_flag = reaper.GetEnvelopePointEx(env, -1, i)
    if ok and sel_flag then
      reaper.SetEnvelopePointEx(env, -1, i, t, v, sh, tn_val, false, true)
      changed = true
    end
  end
  if changed then
    reaper.Envelope_SortPointsEx(env, -1)
    reaper.UpdateArrange()
  end
end

-- ── Selection save / restore ─────────────────────────────────

-- Saves the current AI and envelope point selection before starting a capture.
-- Returns a saved_sel table usable with restoreSelection().
function M.saveSelection()
  local saved = { ais = {}, env_pts = nil }

  for ti = 0, reaper.CountTracks(0) - 1 do
    local track = reaper.GetTrack(0, ti)
    for ei = 0, reaper.CountTrackEnvelopes(track) - 1 do
      local env = reaper.GetTrackEnvelope(track, ei)
      for ai = 0, reaper.CountAutomationItems(env) - 1 do
        if reaper.GetSetAutomationItemInfo(env, ai, "D_UISEL", 0, false) == 1 then
          saved.ais[#saved.ais+1] = { track_idx=ti, env_idx=ei, ai_idx=ai }
        end
      end
    end
  end

  local env = M.getActiveEnvelope()
  if env then
    local indices = {}
    local n = reaper.CountEnvelopePointsEx(env, -1)
    for i = 0, n - 1 do
      local ok, _, _, _, _, sel_flag = reaper.GetEnvelopePointEx(env, -1, i)
      if ok and sel_flag then indices[#indices+1] = i end
    end
    if #indices > 0 then
      saved.env_pts = { env=env, indices=indices }
    end
  end

  return saved
end

-- Restores a selection previously saved with saveSelection().
function M.restoreSelection(saved)
  if not saved then return end

  for _, entry in ipairs(saved.ais) do
    local track = reaper.GetTrack(0, entry.track_idx)
    if track then
      local env = reaper.GetTrackEnvelope(track, entry.env_idx)
      if env and entry.ai_idx < reaper.CountAutomationItems(env) then
        reaper.GetSetAutomationItemInfo(env, entry.ai_idx, "D_UISEL", 1, true)
      end
    end
  end

  if saved.env_pts then
    local env     = saved.env_pts.env
    local n       = reaper.CountEnvelopePointsEx(env, -1)
    local changed = false
    for _, idx in ipairs(saved.env_pts.indices) do
      if idx < n then
        local ok, t, v, sh, tn_val = reaper.GetEnvelopePointEx(env, -1, idx)
        if ok then
          reaper.SetEnvelopePointEx(env, -1, idx, t, v, sh, tn_val, true, true)
          changed = true
        end
      end
    end
    if changed then
      reaper.Envelope_SortPointsEx(env, -1)
      reaper.UpdateArrange()
    end
  end
end

-- ── Item utilities ───────────────────────────────────────────

-- Returns the 1-based index of an item on its track, or nil.
function M.getItemIndexOnTrack(item)
  if not item then return nil end
  local track = reaper.GetMediaItemTrack(item)
  if not track then return nil end
  local n = reaper.CountTrackMediaItems(track)
  for i = 0, n - 1 do
    if reaper.GetTrackMediaItem(track, i) == item then
      return i + 1
    end
  end
  return nil
end

-- ── Context detection ─────────────────────────────────────────
-- Mirrors the target-resolution logic in Generate.lua so that
-- the context panel and INSERT buttons stay consistent.
-- Returns a context table:
--   has_target   : boolean — a valid writable target exists
--   track_num    : number|nil
--   env_name     : string|nil
--   cursor       : number — edit cursor position
--   ts_s, ts_e   : number — time selection bounds
--   use_ts       : boolean — true when a valid time selection exists
--   is_item_env  : boolean — target is a take/item-FX envelope
--   is_tempo_env : boolean — target is the Tempo Map envelope
--   item_idx     : number|nil — 1-based item index on its track
--   item_count   : number — selected item count (0 for track envelopes)
--   all_items_ok : boolean — all selected items have a visible FX envelope
function M.getContextInfo()
  local cursor     = reaper.GetCursorPosition()
  local ts_s, ts_e = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  local use_ts     = (ts_e - ts_s >= 0.01)
  local track_num, env_name, is_item_env, item_idx

  -- Case 1: explicitly selected envelope
  local sel_env = reaper.GetSelectedEnvelope(0)
  if sel_env then
    local _, n = reaper.GetEnvelopeName(sel_env)
    env_name   = n
    local p_take  = reaper.GetEnvelopeInfo_Value(sel_env, "P_TAKE")
    local p_track = reaper.GetEnvelopeInfo_Value(sel_env, "P_TRACK")
    if p_take and p_take ~= 0 then
      is_item_env = true
      local pitem = reaper.GetMediaItemTake_Item(p_take)
      if pitem then
        item_idx     = M.getItemIndexOnTrack(pitem)
        local ptrack = reaper.GetMediaItemTrack(pitem)
        if ptrack then
          track_num = math.floor(reaper.GetMediaTrackInfo_Value(ptrack, "IP_TRACKNUMBER"))
        end
      end
    elseif p_track and p_track ~= 0 then
      is_item_env = false
      track_num   = math.floor(reaper.GetMediaTrackInfo_Value(p_track, "IP_TRACKNUMBER"))
    end

    local visible = false
    do
      local ok, chunk = reaper.GetEnvelopeStateChunk(sel_env, "", false)
      if ok and chunk and #chunk > 0 then
        local vis = chunk:match("\nVIS (%d)")
        local act = chunk:match("\nACT (%d)")
        visible = (not vis or tonumber(vis) == 1) and (not act or tonumber(act) == 1)
      else
        local h = reaper.GetEnvelopeInfo_Value(sel_env, "I_TCPH")
        visible = h ~= nil and h > 0
      end
    end

    local is_tempo_env = false
    do
      local _, en = reaper.GetEnvelopeName(sel_env)
      is_tempo_env = (en == "Tempo map")
    end

    return {
      has_target   = visible,
      track_num    = track_num,
      env_name     = env_name,
      cursor       = cursor,
      ts_s         = ts_s,
      ts_e         = ts_e,
      use_ts       = use_ts,
      is_item_env  = is_item_env,
      is_tempo_env = is_tempo_env,
      item_idx     = item_idx,
      item_count   = 0,
      all_items_ok = visible,
    }
  end

  -- Case 2: selected media items
  local n_sel = reaper.CountSelectedMediaItems(0)
  if n_sel > 0 then
    local all_ok      = true
    local first_ename = nil
    local mixed       = false

    for i = 0, n_sel - 1 do
      local item          = reaper.GetSelectedMediaItem(0, i)
      local take          = reaper.GetActiveTake(item)
      local found_visible = false
      if take then
        for ei = 0, reaper.CountTakeEnvelopes(take) - 1 do
          local e       = reaper.GetTakeEnvelope(take, ei)
          local ok, chunk = reaper.GetEnvelopeStateChunk(e, "", false)
          local visible = false
          if ok and chunk and #chunk > 0 then
            local vis = chunk:match("\nVIS (%d)")
            local act = chunk:match("\nACT (%d)")
            visible = (not vis or tonumber(vis) == 1) and (not act or tonumber(act) == 1)
          else
            local h = reaper.GetEnvelopeInfo_Value(e, "I_TCPH")
            visible = h ~= nil and h > 0
          end
          if visible then
            local _, en = reaper.GetEnvelopeName(e)
            if not first_ename then
              first_ename = en
            elseif en ~= first_ename then
              mixed = true
            end
            if i == 0 then
              item_idx     = M.getItemIndexOnTrack(item)
              local ptrack = reaper.GetMediaItemTrack(item)
              if ptrack then
                track_num = math.floor(reaper.GetMediaTrackInfo_Value(ptrack, "IP_TRACKNUMBER"))
              end
            end
            found_visible = true
            break
          end
        end
      end
      if not found_visible then all_ok = false end
    end

    env_name = mixed and "mixed" or first_ename
    return {
      has_target   = all_ok,
      track_num    = track_num,
      env_name     = env_name,
      cursor       = cursor,
      ts_s         = ts_s,
      ts_e         = ts_e,
      use_ts       = use_ts,
      is_item_env  = true,
      is_tempo_env = false,
      item_idx     = item_idx,
      item_count   = n_sel,
      all_items_ok = all_ok,
    }
  end

  -- Case 3: track only — no auto-pick, has_target = false
  local sel_track = reaper.GetSelectedTrack(0, 0)
  if sel_track then
    track_num   = math.floor(reaper.GetMediaTrackInfo_Value(sel_track, "IP_TRACKNUMBER"))
    is_item_env = false
  end
  return {
    has_target   = false,
    track_num    = track_num,
    env_name     = nil,
    cursor       = cursor,
    ts_s         = ts_s,
    ts_e         = ts_e,
    use_ts       = use_ts,
    is_item_env  = is_item_env or false,
    is_tempo_env = false,
    item_idx     = nil,
    item_count   = 0,
    all_items_ok = false,
  }
end

return M