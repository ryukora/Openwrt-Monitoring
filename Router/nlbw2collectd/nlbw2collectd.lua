-- nlbw2collectd.lua (final stable, fixed argument order)
-- Based on https://github.com/mstojek/nlbw2collectd
-- Enhanced to skip idle devices and avoid RRD spam
-- Works with collectd -> network -> Prometheus (no local rrdtool needed)

require "luci.jsonc"
local io = require "io"

local HOSTNAME = '' -- leave empty if local
local PLUGIN = "nlbwmon"
local PLUGIN_INSTANCE_RX = "nlbwmon_rx"
local PLUGIN_INSTANCE_TX = "nlbwmon_tx"
local TYPE_BYTES = "ipt_bytes"
local TYPE_PACKETS = "ipt_packets"
local TYPE_INSTANCE_PREFIX_RX = "rx_"
local TYPE_INSTANCE_PREFIX_TX = "tx_"

local function isempty(s)
    return s == nil or s == ''
end

local function exec(command)
    local pp = io.popen(command)
    local data = pp:read("*a")
    pp:close()
    return data
end

-- hostname resolver: DHCP lease -> static host mapping -> nslookup -> fallback ip
local function lookup(ip)
    local client

    -- dnsmasq lease file
    local lease_file = exec("uci get dhcp.@dnsmasq[0].leasefile 2>/dev/null")
    lease_file = lease_file:gsub('[%c]', '')
    if not isempty(lease_file) then
        local cmd = "grep \"\\b" .. ip .. "\\b\" " .. lease_file .. " | awk '{print $4}'"
        client = exec(cmd)
        client = client:gsub('[%c]', '')
    end

    if isempty(client) then
        -- reverse dns
        local cmd = "nslookup " .. ip .. " 2>/dev/null | grep 'name = ' | sed -E 's/^.*name = ([a-zA-Z0-9_.-]+).*$/\\1/'"
        client = exec(cmd)
        client = client:gsub('[%c]', '')
    end

    if isempty(client) or client == '*' then
        client = ip
    end

    return client
end

-- read list of known clients (DHCP leases + static hosts)
local function get_known_clients()
    local known = {}

    -- dynamic leases: /tmp/dhcp.leases
    local f = io.open("/tmp/dhcp.leases", "r")
    if f then
        for line in f:lines() do
            -- ts mac ip name id
            local ts, mac, ip, name = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            if ip then
                if name ~= "*" then
                    known[ip] = name
                else
                    known[ip] = ip
                end
            end
        end
        f:close()
    end

    -- static leases: dhcp.@host[*]
    local idx = 0
    while true do
        local ip = exec("uci get dhcp.@host["..idx.."].ip 2>/dev/null")
        if ip == nil or ip == '' then break end
        ip = ip:gsub('[%c]', '')

        local nm = exec("uci get dhcp.@host["..idx.."].name 2>/dev/null")
        nm = nm:gsub('[%c]', '')
        if isempty(nm) then nm = ip end

        known[ip] = nm
        idx = idx + 1
    end

    return known
end

-- send one client's 4 metrics to collectd
local function dispatch_sample(client, tx_bytes, rx_bytes, tx_packets, rx_packets)
    -- guard: skip incomplete samples
    if not (tx_bytes and rx_bytes and tx_packets and rx_packets) then
        return
    end

    -- bytes modulo to avoid 32-bit rollover in rrd-style DS types
    local tx_b = {
        host = HOSTNAME,
        plugin = PLUGIN,
        plugin_instance = PLUGIN_INSTANCE_TX,
        type = TYPE_BYTES,
        type_instance = TYPE_INSTANCE_PREFIX_TX .. client,
        values = { tx_bytes % 2147483647 },
    }
    collectd.dispatch_values(tx_b)

    local rx_b = {
        host = HOSTNAME,
        plugin = PLUGIN,
        plugin_instance = PLUGIN_INSTANCE_RX,
        type = TYPE_BYTES,
        type_instance = TYPE_INSTANCE_PREFIX_RX .. client,
        values = { rx_bytes % 2147483647 },
    }
    collectd.dispatch_values(rx_b)

    local tx_p = {
        host = HOSTNAME,
        plugin = PLUGIN,
        plugin_instance = PLUGIN_INSTANCE_TX,
        type = TYPE_PACKETS,
        type_instance = TYPE_INSTANCE_PREFIX_TX .. client,
        values = { tx_packets },
    }
    collectd.dispatch_values(tx_p)

    local rx_p = {
        host = HOSTNAME,
        plugin = PLUGIN,
        plugin_instance = PLUGIN_INSTANCE_RX,
        type = TYPE_PACKETS,
        type_instance = TYPE_INSTANCE_PREFIX_RX .. client,
        values = { rx_packets },
    }
    collectd.dispatch_values(rx_p)
end

function read()
    -- STEP 1: live usage from nlbwmon
    local json_raw = exec("/usr/sbin/nlbw -c json -g ip 2>/dev/null")
    local parsed = luci.jsonc.parse(json_raw)
    if not parsed or not parsed.data then
        parsed = { data = {} }
    end

    -- usage[ip] = {...}
    local usage = {}
    for _, entry in ipairs(parsed.data) do
        -- nlbw json columns:
        -- [1]=ip [2]=mac [3]=tx_bytes [4]=tx_pkts [5]=rx_bytes [6]=rx_pkts ...
        local ip         = entry[1]
        local tx_bytes   = entry[3]
        local tx_packets = entry[4]
        local rx_bytes   = entry[5]
        local rx_packets = entry[6]

        local clientname = lookup(ip)

        usage[ip] = {
            name        = clientname,
            tx_bytes    = tx_bytes,
            rx_bytes    = rx_bytes,
            tx_packets  = tx_packets,
            rx_packets  = rx_packets
        }
    end

    -- STEP 2: known inventory
    local known = get_known_clients()

    -- STEP 3: for each known IP, only send if it actually talked
    for ip, _ in pairs(known) do
        local u = usage[ip]
        if u ~= nil then
            dispatch_sample(
                u.name,
                u.tx_bytes,
                u.rx_bytes,
                u.tx_packets,
                u.rx_packets
            )
        end
    end

    return 0
end

collectd.register_read(read)
