local function scrape()
  local new_device = metric("router_new_device", "gauge")

  local file = io.open("/tmp/99-new_device.out", "r")
  if not file then
    return
  end

  for line in file:lines() do
    local date, device, ip, mac, bytes
    bytes = 0  -- Default value

    for _, field in ipairs(space_split(line)) do
      if not date and field:match("^date") then
        date = field:match("date=([^,]+)")
      elseif not device and field:match("^device") then
        device = field:match("device=([^,]+)")
      elseif not ip and field:match("^ip") then
        ip = field:match("ip=([^,]+)")
      elseif not mac and field:match("^mac") then
        mac = field:match("mac=([^,]+)")
      elseif field:match("^bytes") then
        local b = field:match("bytes=([^,]+)")
        bytes = bytes + (tonumber(b) or 0)  -- Ensure numeric conversion
      end
    end

    if date and device and ip and mac then
      local labels = { date = date, device = device, ip = ip, mac = mac }
      new_device(labels, bytes)
    end
  end

  file:close()
end

return { scrape = scrape }
