-- Sourced from on 12/29/24 = https://raw.githubusercontent.com/mstojek/nlbw2collectd/refs/heads/main/nlbw2collectd.lua
-- Fixed for nil JSON handling, robust JSON, optional DNS, caching, client cap, safe labels
-- Base = https://github.com/mstojek/nlbw2collectd

require "luci.jsonc"
-- require "luci.sys"
-- require "luci.util"
local io = require "io"
local os = require "os"

-- ==== TUNABLES ==============================================================
local HOSTNAME = ''                           -- leave empty if you track statistics for the local system, change when you really know that you want a different hostname to be used
local RESOLVE_HOSTNAMES = false               -- true for use host name; default off (lebih ringan)
local DNS_CACHE_TTL = 300                     -- second
local MAX_CLIENTS = 200                       -- limit the number of clients read/dispatched per cycle
local LOG_FAIL_EVERY = 12                     -- log error every n failures (rate-limit)
local NLBW_CMD = "/usr/sbin/nlbw -c json -g ip"
local PLUGIN = "iptables"
local PLUGIN_INSTANCE_RX = "mangle-iptmon_rx" -- change to "mangle-iptmon_rx" to have full compliance with iptmon
local PLUGIN_INSTANCE_TX = "mangle-iptmon_tx" -- change to "mangle-iptmon_tx" to have full compliance with iptmon
local TYPE_BYTES = "ipt_bytes"
local TYPE_PACKETS = "ipt_packets"
local TYPE_INSTANCE_PREFIX_RX = "rx_"
local TYPE_INSTANCE_PREFIX_TX = "tx_"
-- ===========================================================================

local fail_count = 0
local dns_cache = {}  -- ip -> {name=..., ts=...}

local function now() return os.time() end

local function isempty(s) return s == nil or s == '' end

local function sanitize(s)
  s = tostring(s or "")
  -- collectd type_instance much safer if alnum, _ , - , .
  s = s:gsub("%s+", "_")
  s = s:gsub("[^%w%._%-]", "_")
  -- protect string empty
  if isempty(s) then s = "unknown" end
  return s
end

local function exec(command)
  local pp = io.popen(command)
  if not pp then return nil end
  local data = pp:read("*a")
  pp:close()
  return data
end

local function lookup(ip)
  if not RESOLVE_HOSTNAMES then
    return ip
  end

  local entry = dns_cache[ip]
  local t = now()
  if entry and (t - entry.ts) < DNS_CACHE_TTL then
    return entry.name
  end

  -- 1) DHCP lease
  -- First check the lease file for hostname
  -- local lease_file=luci.sys.exec("uci get dhcp.@dnsmasq[0].leasefile")
  local lease_file = exec("uci get dhcp.@dnsmasq[0].leasefile") or ""
  lease_file = lease_file:gsub("[%c]", "")
  local cmd = string.format("grep \"\\b%s\\b\" %s 2>/dev/null | awk '{print $4}'", ip, lease_file)
  -- local client=luci.sys.exec(command)
  local client = exec(cmd) or ""
  client = client:gsub("[%c]", "")

  -- 2) nslookup (optional, can be heavy)
  if isempty(client) or client == "*" then
	-- Try with nslookup then
    client = exec("nslookup " .. ip .. " 2>/dev/null | grep 'name = ' | sed -E 's/^.*name = ([A-Za-z0-9.-]+).*$/\\1/'") or ""
    -- client = luci.sys.exec(command)
    client = client:gsub("[%c]", "")
  end

  if isempty(client) or client == "*" then
    client = ip
  end

  client = sanitize(client)
  dns_cache[ip] = { name = client, ts = t }
  return client
end

local function to_num(x)
  local n = tonumber(x)
  if not n or n < 0 then n = 0 end
  return n
end

local function dispatch_pair(client, tx_bytes, tx_pkts, rx_bytes, rx_pkts)
  -- modulo workaround (RRD 32-bit types)
  local tx_b_mod = tx_bytes % 2147483647
  local rx_b_mod = rx_bytes % 2147483647

  collectd.dispatch_values({
    host = HOSTNAME,
    plugin = PLUGIN,
    plugin_instance = PLUGIN_INSTANCE_TX,
    type = TYPE_BYTES,
    type_instance = TYPE_INSTANCE_PREFIX_TX .. client,
    values = { tx_b_mod },
  })

  collectd.dispatch_values({
    host = HOSTNAME,
    plugin = PLUGIN,
    plugin_instance = PLUGIN_INSTANCE_RX,
    type = TYPE_BYTES,
    type_instance = TYPE_INSTANCE_PREFIX_RX .. client,
    values = { rx_b_mod },
  })

  collectd.dispatch_values({
    host = HOSTNAME,
    plugin = PLUGIN,
    plugin_instance = PLUGIN_INSTANCE_TX,
    type = TYPE_PACKETS,
    type_instance = TYPE_INSTANCE_PREFIX_TX .. client,
    values = { tx_pkts },
  })

  collectd.dispatch_values({
    host = HOSTNAME,
    plugin = PLUGIN,
    plugin_instance = PLUGIN_INSTANCE_RX,
    type = TYPE_PACKETS,
    type_instance = TYPE_INSTANCE_PREFIX_RX .. client,
    values = { rx_pkts },
  })
end

function read()
  -- Get JSON data from nlbw
  -- collectd.log_info("read function called")
  -- local json = luci.sys.exec("/usr/sbin/nlbw -c json -g ip")
  local json = exec(NLBW_CMD)
  if not json or isempty(json) then
    fail_count = fail_count + 1
    if (fail_count % LOG_FAIL_EVERY) == 1 then
	  -- collectd.log_info("exec function called")
      collectd.log_error("nlbw2collectd: empty output from nlbw")
	  -- collectd.log_info("Json: " .. json)
    end
    return 0
  end

  local ok, pjson = pcall(luci.jsonc.parse, json)
  if not ok or not pjson or type(pjson) ~= "table" or type(pjson.data) ~= "table" then
    fail_count = fail_count + 1
    if (fail_count % LOG_FAIL_EVERY) == 1 then
      collectd.log_error("nlbw2collectd: failed to parse JSON or no data")
    end
    return 0
  end

  fail_count = 0

  local count = 0
  for _, v in ipairs(pjson.data) do
    -- Expected: { ip, ?name?, tx_bytes, tx_packets, rx_bytes, rx_packets }
	-- command = "nslookup " .. ip .. " | grep 'name = ' | sed -E 's/^.*name = ([a-zA-Z0-9-]+).*$/\\1/'"
    -- local client = exec(command)
	
	-- TX, RX Bytes & Packets
    local ip        = sanitize(v[1] or "0.0.0.0")
    local tx_bytes  = to_num(v[3])
    local tx_pkts   = to_num(v[4])
    local rx_bytes  = to_num(v[5])
    local rx_pkts   = to_num(v[6])

    local client = lookup(ip)

	-- collectd.log_info("ip: " .. ip .. " , client: " .. client)

    dispatch_pair(client, tx_bytes, tx_pkts, rx_bytes, rx_pkts)

    count = count + 1
    if count >= MAX_CLIENTS then
      break
    end
  end

  return 0
end

collectd.register_read(read) -- pass function as variable
