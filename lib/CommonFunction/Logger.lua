-- ============================================================
--   Logger.lua
--   Centralized message bus.
--   Decouples message production (services) from display (UI).
--   Usage:
--     Logger.ok("✔ Done")       → green status
--     Logger.error("⚠ Failed")  → red blinking status
--     local msg, is_ok = Logger.get()
-- ============================================================

local M = {}

local _msg   = "Capture Source 1 & Source 2"
local _is_ok = true

-- Set a success / informational message.
function M.ok(msg)
  _msg   = msg or ""
  _is_ok = true
end

-- Set an error message (UI will display it in red with blink).
function M.error(msg)
  _msg   = msg or ""
  _is_ok = false
end

-- Returns (message_string, is_ok_boolean).
function M.get()
  return _msg, _is_ok
end

return M
