-- unified Prometheus collector + collectd script
-- Works in:
--  1) Prometheus collector module (returns { scrape = ... })
--  2) collectd Lua plugin (auto-registers)

-- =========================
-- Config
-- =========================
local DEFAULT_FILE_PATH = "/tmp/device-status.out"

-- Allow override via environment variable (if your launcher sets it)
local function getenv(name)
  local ok, uv = pcall(require, "uv")
  if ok and uv and uv.os_getenv then
    return uv.os_getenv(name)
  end
  return os.getenv and os.getenv(name) or nil
end

local FILE_PATH = getenv("DEVICE_STATUS_FILE") or DEFAULT_FILE_PATH

-- =========================
-- Helpers (no globals leaked)
-- =========================
local function parse_line(line)
  -- Parse k=v tokens separated by spaces; supports arbitrary order
  -- Example: device=phone mac=AA:BB ip=192.0.2.3 status=online bytes=123 bytes=77
  local data = { bytes = 0 }
  for key, value in line:gmatch("(%w+)=([^%s]+)") do
    if key == "bytes" then
      local n = tonumber(value) or 0
      data.bytes = (data.bytes or 0) + n
    else
      data[key] = value
    end
  end
  return data
end

local function read_lines(path)
  local f, err = io.open(path, "r")
  if not f then
    return nil, ("cannot open %s: %s"):format(path, err or "unknown error")
  end
  local lines = {}
  for ln in f:lines() do
    if ln and ln:match("%S") then
      lines[#lines + 1] = ln
    end
  end
  f:close()
  return lines
end

local function status_to_num(status)
  if not status then return 0 end
  -- Normalize: accept common truthy words or any positive number
  local s = tostring(status):lower()
  if s == "online" or s == "up" or s == "active" or s == "true" or s == "1" then
    return 1
  end
  local n = tonumber(s)
  if n and n > 0 then return 1 end
  return 0
end

-- =========================
-- Prometheus exporter path
-- (expects global `metric(name, type)` and returns a callable)
-- =========================
local function scrape_prometheus(file_path)
  -- Backward-compatible metric: original code used router_device_status = BYTES
  local device_status_bytes = metric("router_device_status", "gauge")

  -- New, clearer metrics (kept as gauge to match environment expectations)
  local device_up           = metric("router_device_up", "gauge")
  local device_bytes        = metric("router_device_bytes", "gauge")

  local lines, err = read_lines(file_path)
  if not lines then
    -- If Prometheus collector runner shows logs, this is helpful; otherwise, it’s silent.
    -- Avoid throwing, so the rest of the collectors still work.
    return
  end

  for _, ln in ipairs(lines) do
    local d = parse_line(ln)
    if d.device then
      local labels = {
        device = d.device or "unknown",
        mac    = d.mac or "unknown",
        ip     = d.ip or "unknown",
        status = d.status or "unknown",
      }
      local up = status_to_num(d.status)
      local bytes = tonumber(d.bytes) or 0

      -- Back-compat: original metric name carried bytes value
      device_status_bytes(labels, bytes)

      -- New: explicit up + bytes (mirrors collectd dispatch below)
      device_up(labels, up)
      device_bytes(labels, bytes)
    end
  end
end

-- =========================
-- collectd plugin path
-- =========================
local function collectd_dispatch(file_path)
  if not collectd then return end

  local lines, err = read_lines(file_path)
  if not lines then
    collectd.warning(("device_status: %s"):format(err))
    return 0
  end

  for _, ln in ipairs(lines) do
    local d = parse_line(ln)
    if d.device then
      local dev   = d.device
      local up    = status_to_num(d.status)
      local bytes = tonumber(d.bytes) or 0

      -- Status (0/1)
      collectd.dispatch_values({
        plugin         = "device_status",
        type           = "gauge",
        type_instance  = dev .. "_up",
        values         = { up },
      })

      -- Bytes (kept as gauge unless you define a proper types.db for 'bytes'/'derive')
      collectd.dispatch_values({
        plugin         = "device_status",
        type           = "gauge",
        type_instance  = dev .. "_bytes",
        values         = { bytes },
      })
    end
  end

  return 0
end

-- If running inside collectd, register read callback once.
local function register_collectd()
  if not collectd then return end
  local plugin_name = "device_status"

  -- Optional: allow override via collectd.conf `env` to change file path
  local ok_env, ce = pcall(function() return collectd.get_dataset end)
  -- (not strictly needed; just keeping minimal dependencies)

  collectd.register_read(function()
    return collectd_dispatch(FILE_PATH)
  end, plugin_name)

  collectd.info(plugin_name .. ": registered read callback, file=" .. FILE_PATH)
end

-- Auto-register for collectd if present
pcall(register_collectd)

-- =========================
-- Public API for Prometheus runner
-- =========================
local M = {}

function M.scrape(path_override)
  local p = path_override or FILE_PATH
  -- Only run the Prometheus scrape if metric() exists (Prometheus collectors env)
  if type(metric) == "function" then
    return scrape_prometheus(p)
  end
  -- If someone calls scrape() outside the Prometheus env, do nothing gracefully.
  return
end

return M
