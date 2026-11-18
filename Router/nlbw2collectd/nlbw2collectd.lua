-- nlbw2collectd.lua
-- Copies per-device traffic counters from nlbwmon into collectd.
-- Based on https://github.com/mstojek/nlbw2collectd
--
-- Works on OpenWrt 24.x (opkg) and 25.x (apk) with fw4/nftables.
-- Needs: nlbwmon, collectd-mod-lua, luci-lib-jsonc
--
-- Values dispatched (collectd -> network plugin -> collectd-exporter -> Prometheus):
--   plugin=nlbwmon plugin_instance=nlbwmon_rx type=ipt_bytes   type_instance=<device>   (download)
--   plugin=nlbwmon plugin_instance=nlbwmon_tx type=ipt_bytes   type_instance=<device>   (upload)
--   plugin=nlbwmon plugin_instance=nlbwmon_rx type=ipt_packets type_instance=<device>
--   plugin=nlbwmon plugin_instance=nlbwmon_tx type=ipt_packets type_instance=<device>
--
-- In Prometheus (prom/collectd-exporter) this becomes:
--   collectd_nlbwmon_ipt_bytes_total{nlbwmon="nlbwmon_rx", type="<device>"}
--   collectd_nlbwmon_ipt_bytes_total{nlbwmon="nlbwmon_tx", type="<device>"}
--
-- Only devices found in the DHCP leases or static DHCP hosts are reported,
-- and only when nlbwmon has seen traffic for them.

require "luci.jsonc"
local io = require "io"

local PLUGIN = "nlbwmon"
local PLUGIN_INSTANCE_RX = "nlbwmon_rx"
local PLUGIN_INSTANCE_TX = "nlbwmon_tx"
local TYPE_BYTES = "ipt_bytes"
local TYPE_PACKETS = "ipt_packets"
local LEASE_FILE = "/tmp/dhcp.leases"

-- Keep values below 2^31 so they survive the Lua -> collectd integer
-- conversion on 32-bit routers. Prometheus treats the wrap as a counter reset.
local WRAP = 2147483647

local function exec(command)
    local pp = io.popen(command)
    if not pp then
        return ""
    end
    local data = pp:read("*a") or ""
    pp:close()
    return data
end

local function trim(s)
    local out = (s or ""):gsub("[%c]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return out
end

-- collectd type_instance must not contain '/' and should stay short
local function sanitize(name)
    name = name:gsub("[^%w%._%-]", "_")
    return name:sub(1, 63)
end

-- Known clients: DHCP leases + static DHCP hosts -> { [ip] = name }
local function get_known_clients()
    local known = {}

    local f = io.open(LEASE_FILE, "r")
    if f then
        for line in f:lines() do
            -- <expiry> <mac> <ip> <hostname> <client-id>
            local _, _, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if ip then
                if name == nil or name == "*" or name == "" then
                    name = ip
                end
                known[ip] = name
            end
        end
        f:close()
    end

    local idx = 0
    while true do
        local ip = trim(exec("uci -q get dhcp.@host[" .. idx .. "].ip"))
        if ip == "" then
            -- stop when the section does not exist at all
            if trim(exec("uci -q get dhcp.@host[" .. idx .. "]")) == "" then
                break
            end
        else
            local nm = trim(exec("uci -q get dhcp.@host[" .. idx .. "].name"))
            if nm == "" then
                nm = ip
            end
            known[ip] = nm
        end
        idx = idx + 1
    end

    return known
end

local function dispatch(instance, typ, client, value)
    collectd.dispatch_values({
        plugin = PLUGIN,
        plugin_instance = instance,
        type = typ,
        type_instance = client,
        values = { value % WRAP },
    })
end

function read()
    local parsed = luci.jsonc.parse(exec("/usr/sbin/nlbw -c json -g ip 2>/dev/null"))
    if type(parsed) ~= "table" or type(parsed.columns) ~= "table" or type(parsed.data) ~= "table" then
        return 0
    end

    -- Resolve column positions by name instead of guessing the order.
    -- `nlbw -c json -g ip` returns: ip, conns, rx_bytes, rx_pkts, tx_bytes, tx_pkts
    local col = {}
    for i, name in ipairs(parsed.columns) do
        col[name] = i
    end
    if not (col.ip and col.rx_bytes and col.rx_pkts and col.tx_bytes and col.tx_pkts) then
        return 0
    end

    local known = get_known_clients()
    local used = {}

    for _, row in ipairs(parsed.data) do
        local ip = row[col.ip]
        local name = ip and known[ip]

        if name then
            local client = sanitize(name)
            -- two devices with the same hostname: keep them apart
            if used[client] then
                client = sanitize(name .. "_" .. ip)
            end
            used[client] = true
            local rx_bytes = tonumber(row[col.rx_bytes])
            local rx_pkts  = tonumber(row[col.rx_pkts])
            local tx_bytes = tonumber(row[col.tx_bytes])
            local tx_pkts  = tonumber(row[col.tx_pkts])

            if rx_bytes and rx_pkts and tx_bytes and tx_pkts then
                -- rx = received by the LAN device (download)
                dispatch(PLUGIN_INSTANCE_RX, TYPE_BYTES, client, rx_bytes)
                dispatch(PLUGIN_INSTANCE_RX, TYPE_PACKETS, client, rx_pkts)
                -- tx = sent by the LAN device (upload)
                dispatch(PLUGIN_INSTANCE_TX, TYPE_BYTES, client, tx_bytes)
                dispatch(PLUGIN_INSTANCE_TX, TYPE_PACKETS, client, tx_pkts)
            end
        end
    end

    return 0
end

collectd.register_read(read)
