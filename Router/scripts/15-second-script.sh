#!/bin/sh
# set -x
#---------------------------------------------------------------------------------------------------------#
#wrtbwmon script will run every
#wrtbwmon update /tmp/usage.db
#wrtbwmon publish /tmp/usage.db /tmp/usage.htm
#cat /tmp/usage.htm | grep "2025" | sed 's/,/  /g; s/"//g; s/new Array//g' | tr -d '()' | sed '$d' > /tmp/bwmon_usage.out

#---------------------------------------------------------------------------------------------------------#
#Get Temp and Fan speed for GL-Routers
#temp=`cat /sys/class/thermal/thermal_zone0/temp`
#speed=`gl_fan -s`
#echo "$temp $speed" > /tmp/tempstats.out

#---------------------------------------------------------------------------------------------------------#
# Network Clients Discovery Script for OpenWRT
# Run interval: 15s (e.g., via cron or procd timer)

set -u  # fail on unset vars (BusyBox safe)

# ---- Paths & constants -------------------------------------------------------
OUT_TXT="/tmp/clientlist.out"
OUT_HTML="/tmp/clientlist.html"
LEASES_FILE="/tmp/dhcp.leases"
ARP_FILE="/proc/net/arp"
LOCK_FILE="/tmp/clientlist.lock"
WWW_LINK="/www/clientlist.html"

# Optional: include IPv6 neighbors (ip -6 neigh). Leave a comment if you don’t want it.
IPV6_NEIGH=0
IP6_NEIGH_FILE="/tmp/ip6.neigh"   # temp cache when IPV6_NEIGH=1

# ---- Locking so jobs don’t overlap -------------------------------------------
# Requires /bin/lock (present on OpenWRT by default)
if command -v lock >/dev/null 2>&1; then
  lock -n "$LOCK_FILE" || exit 0
  UNLOCK() { lock -u "$LOCK_FILE"; }
else
  # Fallback lock (best-effort)
  LOCKDIR="/tmp/.clientlist.lockdir"
  if ! mkdir "$LOCKDIR" 2>/dev/null; then
    exit 0
  fi
  UNLOCK() { rmdir "$LOCKDIR" 2>/dev/null; }
fi
trap UNLOCK EXIT

# ---- Make atomic temp files --------------------------------------------------
TMP_TXT="$(mktemp /tmp/clientlist.out.XXXXXX)" || exit 1
TMP_HTML="$(mktemp /tmp/clientlist.html.XXXXXX)" || { rm -f "$TMP_TXT"; exit 1; }

# ---- Gather inputs safely ----------------------------------------------------
HAS_LEASES=0
if [ -s "$LEASES_FILE" ]; then
  HAS_LEASES=1
fi

HAS_ARP=0
if [ -s "$ARP_FILE" ]; then
  HAS_ARP=1
fi

if [ "$IPV6_NEIGH" -eq 1 ] && command -v ip >/dev/null 2>&1; then
  ip -6 neigh show nud reachable nud stale nud delay nud probe 2>/dev/null \
    | awk '{print $1, $(NF-2)}' > "$IP6_NEIGH_FILE" 2>/dev/null || true
fi

# ---- Build the combined client list (DHCP + ARP [+ IPv6]) --------------------
# Columns: Hostname | MAC | IP | Source
# - DHCP Lease rows from /tmp/dhcp.leases
# - ARP-only rows for IPs not present in leases
# - (Optional) IPv6 neighbors as Source="IPv6 Neigh"
#
# To do all deduping and normalization in a single awk for speed.
{
  echo "HOSTNAME|MAC|IP|SOURCE"

  # 1) DHCP leases
  if [ "$HAS_LEASES" -eq 1 ]; then
    # dnsmasq lease format:
    # <expiry> <mac> <ip> <hostname> <client-id/duid>
    awk -v OFS="|" '
      {
        # Protect against short lines
        expiry=$1; mac=$2; ip=$3; host=$4
        if (ip == "" || mac == "") next
        if (host == "*" || host == "" ) host="Unknown"
        # Uppercase MAC
        for(i=1;i<=length(mac);i++) macU=macU toupper(substr(mac,i,1))
        mac=macU; macU=""
        seen_ip[ip]=1
        # Print fixed width not needed here; we’ll format in HTML/text later
        print host, mac, ip, "DHCP Lease"
      }
    ' "$LEASES_FILE"
  fi

  # 2) ARP table (IPv4 only)
  if [ "$HAS_ARP" -eq 1 ]; then
    # /proc/net/arp format (header then rows):
    # IP address HW type Flags HW address Mask Device
    awk -v OFS="|" '
      NR>1 {
        ip=$1; mac=$4
        if (ip=="" || mac=="" || mac=="00:00:00:00:00:00") next
        # Skip if the IP has already been seen in leases
        if (seen_ip[ip]) next

        # Uppercase MAC
        for(i=1;i<=length(mac);i++) macU=macU toupper(substr(mac,i,1))
        mac=macU; macU=""

        # Avoid duplicate ARP rows (rare, but just in case)
        k=ip "|" mac
        if (seen_arp[k]) next
        seen_arp[k]=1

        print "Unknown", mac, ip, "ARP Only"
      }
    ' "$ARP_FILE"
  fi

  # 3) IPv6 neighbors (optional)
  if [ "$IPV6_NEIGH" -eq 1 ] && [ -s "$IP6_NEIGH_FILE" ]; then
    awk -v OFS="|" '
      {
        ip=$1; mac=$2
        if (ip=="" || mac=="" || mac=="00:00:00:00:00:00") next
        for(i=1;i<=length(mac);i++) macU=macU toupper(substr(mac,i,1))
        mac=macU; macU=""
        k=ip "|" mac
        if (seen_any[k]) next
        seen_any[k]=1
        print "Unknown", mac, ip, "IPv6 Neigh"
      }
    ' "$IP6_NEIGH_FILE"
  fi
} | awk -F'|' '
  NR==1 { next }  # skip header from the first block (we’ll re-add later)
  { rows[++n]=$0 }
  END {
    # Sort by IP-like string (simple lexical works OK for LANs);
    # for a stricter sort, split IP and compare numerically.
    asort(rows)
    print "HOSTNAME|MAC|IP|SOURCE"
    for (i=1;i<=n;i++) print rows[i]
  }
' > "$TMP_TXT"

# If nothing found, add a friendly note
if [ ! -s "$TMP_TXT" ]; then
  {
    echo "HOSTNAME|MAC|IP|SOURCE"
    echo "NoClients|—|—|No data"
  } > "$TMP_TXT"
fi

# ---- Also render a small HTML table (auto-refresh every 15s) -----------------
# To keep it fully self-contained (no external CSS/JS) for LuCI/uhttpd.
{
  echo "<!DOCTYPE html>"
  echo "<html><head><meta charset=\"utf-8\">"
  echo "<meta http-equiv=\"refresh\" content=\"15\">"
  echo "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
  echo "<title>OpenWRT Client List</title>"
  cat <<'CSS'
<style>
body{font-family:system-ui,Segoe UI,Arial,sans-serif;margin:16px;}
h1{font-size:1.25rem;margin:0 0 8px 0}
small{color:#666}
table{border-collapse:collapse;width:100%;margin-top:8px;}
th,td{border:1px solid #ddd;padding:6px 8px;font-size:.95rem;white-space:nowrap}
th{background:#f7f7f7;text-align:left}
tbody tr:nth-child(even){background:#fafafa}
.code{font-family:ui-monospace,Consolas,monospace}
.badge{border:1px solid #ccc;background:#f2f2f2;padding:1px 6px;border-radius:999px;font-size:.8rem}
</style>
CSS
  echo "</head><body>"
  echo "<h1>OpenWRT Client List</h1>"
  printf "<small>Updated: %s</small>\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "<table><thead><tr>"
  echo "<th>Hostname</th><th>MAC</th><th>IP</th><th>Source</th>"
  echo "</tr></thead><tbody>"

  # Convert the pipe-separated file into HTML rows
  awk -F'|' '
    NR==1 { next }  # skip header
    {
      host=$1; mac=$2; ip=$3; src=$4
      # basic HTML escape
      gsub(/&/, "\\&amp;", host); gsub(/</, "\\&lt;", host); gsub(/>/, "\\&gt;", host)
      gsub(/&/, "\\&amp;", mac);  gsub(/</, "\\&lt;", mac);  gsub(/>/, "\\&gt;", mac)
      gsub(/&/, "\\&amp;", ip);   gsub(/</, "\\&lt;", ip);   gsub(/>/, "\\&gt;", ip)
      gsub(/&/, "\\&amp;", src);  gsub(/</, "\\&lt;", src);  gsub(/>/, "\\&gt;", src)
      printf "<tr><td>%s</td><td class=\"code\">%s</td><td class=\"code\">%s</td><td><span class=\"badge\">%s</span></td></tr>\n", host, mac, ip, src
    }
  ' "$TMP_TXT"

  echo "</tbody></table>"
  echo "</body></html>"
} > "$TMP_HTML"

# ---- Atomically publish ------------------------------------------------------
mv -f "$TMP_TXT" "$OUT_TXT"
mv -f "$TMP_HTML" "$OUT_HTML"

# Ensure the web symlink exists and points to HTML (nicer than raw text)
ln -sf "$OUT_HTML" "$WWW_LINK"

exit 0
 
#---------------------------------------------------------------------------------------------------------#
