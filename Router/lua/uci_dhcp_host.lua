local uci = require("uci")

local function scrape()
  local curs = uci.cursor()
  local metric_uci_host = metric("uci_dhcp_host", "gauge")

  curs:foreach("dhcp", "host", function(s)
    if s[".type"] == "host" then
      local mac_val = s["mac"]

      if type(mac_val) == "table" then
        mac_val = mac_val[1] or ""
      end

      if type(mac_val) == "string" then
        mac_val = string.upper(mac_val)
      else
        mac_val = ""
      end

      local labels = {
        name = s["name"] or "",
        mac  = mac_val,
        dns  = s["dns"] or "",
        ip   = s["ip"] or ""
      }

      metric_uci_host(labels, 1)
    end
  end)
end

return { scrape = scrape }
