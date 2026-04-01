-- ============================================================
--   StandaloneWindow.lua
--   Common boilerplate for the standalone loop of each tool.
--   Handles: ImGui window, custom titlebar, dock, collapse, scrollable child.
--
--   Usage:
--     local SW = require("StandaloneWindow")
--     SW.run(ctx, script_name, cfg, draw_ui_fn, opts)
--
--   cfg: {
--     win_w, win_h           -- initial size (FirstUseEver)
--     win_min_w, win_min_h   -- min constraints
--     win_max_w, win_max_h   -- max constraints
--     ext_state_key          -- GetExtState key (e.g. "ReaCurve_LFO")
--   }
--
--   opts (optional): {
--     pre_frame  = function()   -- called before ImGui_Begin (e.g. pollCapture)
--     child_id   = string       -- scrollable BeginChild ID (default auto)
--   }
-- ============================================================

local M = {}

local Theme    = require("Theme")
local TitleBar = require("TitleBar")

local TITLE_H = TitleBar.TITLE_H

-- ── run ──────────────────────────────────────────────────────
function M.run(ctx, script_name, cfg, draw_ui_fn, opts)
  opts = opts or {}

  local COND_FIRST_USE_EVER = reaper.ImGui_Cond_FirstUseEver()
  local T = Theme

  -- Titlebar / dock state (table shared with TitleBar.draw)
  -- "1" = dockable, "0" or absent → non-dockable (disabled by default for standalone)
  local state = {
    collapsed    = false,
    dock_enabled = reaper.GetExtState(cfg.ext_state_key, "dock_en") == "1",
    hover_time   = nil,
  }

  -- Size persisted via ExtState to survive collapse/expand cycles
  local function loadSize()
    local w = tonumber(reaper.GetExtState(cfg.ext_state_key, "win_w"))
    local h = tonumber(reaper.GetExtState(cfg.ext_state_key, "win_h"))
    return (w and w > 0) and w or cfg.win_w,
           (h and h > 0) and h or cfg.win_h
  end
  local saved_w, saved_h = loadSize()

  local expand_frames = 0   -- remaining frames where restored height is forced
  local initialized   = false
  local COND_ALWAYS   = reaper.ImGui_Cond_Always()

  local child_id = opts.child_id or ("##" .. cfg.ext_state_key .. "_content")

  -- ── Main loop ─────────────────────────────────────────────────
  local function loop()
    if reaper.ImGui_IsValid and not reaper.ImGui_IsValid(ctx) then return end

    if opts.pre_frame then opts.pre_frame() end

    -- Window flags: no native titlebar, no scroll on root
    local win_flags = reaper.ImGui_WindowFlags_NoTitleBar()
                    | reaper.ImGui_WindowFlags_NoCollapse()
                    | reaper.ImGui_WindowFlags_NoScrollbar()
                    | reaper.ImGui_WindowFlags_NoScrollWithMouse()
    if not state.dock_enabled and reaper.ImGui_WindowFlags_NoDocking then
      win_flags = win_flags | reaper.ImGui_WindowFlags_NoDocking()
    end

    local min_h = state.collapsed and (TITLE_H + 14) or cfg.win_min_h
    local max_h = state.collapsed and (TITLE_H + 14) or cfg.win_max_h

    -- Size according to state:
    --   collapsed      → force minimum height every frame
    --   expand_frames  → force saved height for N frames (COND_ALWAYS)
    --   init           → COND_FIRST_USE_EVER once only
    --   otherwise      → nothing (ImGui preserves user size)
    if state.collapsed then
      reaper.ImGui_SetNextWindowSize(ctx, saved_w, TITLE_H + 14, COND_ALWAYS)
    elseif expand_frames > 0 then
      reaper.ImGui_SetNextWindowSize(ctx, saved_w, saved_h, COND_ALWAYS)
    elseif not initialized then
      reaper.ImGui_SetNextWindowSize(ctx, saved_w, saved_h, COND_FIRST_USE_EVER)
      initialized = true
    end
    if reaper.ImGui_SetNextWindowSizeConstraints then
      -- Pendant la restauration : pin exact sur saved_w x saved_h pour ce frame
      local cmin_w = expand_frames > 0 and saved_w or cfg.win_min_w
      local cmin_h = expand_frames > 0 and saved_h or min_h
      local cmax_w = expand_frames > 0 and saved_w or cfg.win_max_w
      local cmax_h = expand_frames > 0 and saved_h or max_h
      reaper.ImGui_SetNextWindowSizeConstraints(ctx, cmin_w, cmin_h, cmax_w, cmax_h)
    end

    -- ── Window style ──────────────────────────────────────────────
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_WindowBg(),
      T.hx(T.C_BG_MAIN))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_Border(),
      T.hx(T.C_BORDER, 0.45))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGrip(),
      T.hx(T.C_BORDER, 0.20))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGripHovered(),
      T.hx(T.C_CFG_SEL, 0.55))
    reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ResizeGripActive(),
      T.hx(T.C_CFG_SEL, 0.90))
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowBorderSize(), 1.0)
    reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_WindowPadding(),    8, 6)

    local visible, open = reaper.ImGui_Begin(ctx, script_name, true, win_flags)

    reaper.ImGui_PopStyleColor(ctx, 5)
    reaper.ImGui_PopStyleVar(ctx,   2)

    if visible then
      local dl = reaper.ImGui_GetWindowDrawList(ctx)

      -- Count down forced restore frames
      if expand_frames > 0 then expand_frames = expand_frames - 1 end

      -- Record the actual size when expanded and stable (not during restoration)
      if not state.collapsed and expand_frames == 0 then
        local cw, ch = reaper.ImGui_GetWindowSize(ctx)
        if cw and cw >= cfg.win_min_w and ch and ch > TITLE_H + 20 then
          if cw ~= saved_w or ch ~= saved_h then
            saved_w = cw ; saved_h = ch
            reaper.SetExtState(cfg.ext_state_key, "win_w", tostring(cw), true)
            reaper.SetExtState(cfg.ext_state_key, "win_h", tostring(ch), true)
          end
        end
      end

      -- Custom titlebar (outside the child → always visible even when collapsed)
      local want_close, want_dock, want_collapse = TitleBar.draw(ctx, dl, script_name, state)

      if want_close then open = false end

      if want_dock then
        state.dock_enabled = not state.dock_enabled
        reaper.SetExtState(cfg.ext_state_key, "dock_en",
          state.dock_enabled and "1" or "0", true)
      end

      if want_collapse then
        -- saved_w/h are already up to date (tracked each frame while expanded)
        if state.collapsed then expand_frames = 8 end
        state.collapsed = not state.collapsed
      end

      -- Contenu scrollable dans un BeginChild
      if not state.collapsed then
        reaper.ImGui_PushStyleVar(ctx, reaper.ImGui_StyleVar_ItemSpacing(), 6, 4)
        reaper.ImGui_PushStyleColor(ctx, reaper.ImGui_Col_ChildBg(), T.hx(T.C_BG_MAIN))
        if reaper.ImGui_BeginChild(ctx, child_id, 0, 0, 0, 0) then
          draw_ui_fn(ctx)
          reaper.ImGui_EndChild(ctx)
        end
        reaper.ImGui_PopStyleColor(ctx, 1)
        reaper.ImGui_PopStyleVar(ctx, 1)
      end

      reaper.ImGui_End(ctx)
    end

    if open then reaper.defer(loop) end
  end

  reaper.defer(loop)
end

return M
