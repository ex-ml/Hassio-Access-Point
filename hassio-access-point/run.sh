#!/usr/bin/with-contenv bashio

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
CREATED_BRIDGE=false
term_handler(){
    logger "Stopping Hass.io Access Point" 0
    ifdown "$INTERFACE" 2>/dev/null || true
    ip link set "$INTERFACE" down 2>/dev/null || true
    ip addr flush dev "$INTERFACE" 2>/dev/null || true

    # Clean up bridge wiring performed in AP mode.
    if [ -n "$BRIDGE_DEVICE" ]; then
        if [ -n "$ROUTE_INTERFACE" ] && [ "$BRIDGE_DEVICE" != "$ROUTE_INTERFACE" ]; then
            ip link set "$ROUTE_INTERFACE" nomaster 2>/dev/null || true
        fi

        if [ "$CREATED_BRIDGE" = "true" ]; then
            ip link set "$BRIDGE_DEVICE" down 2>/dev/null || true
            ip link delete "$BRIDGE_DEVICE" type bridge 2>/dev/null || true
        fi
    fi

    exit 0
}

# Logging function to set verbosity of output to addon log
logger(){
    msg=$1
    level=$2
    if [ "$DEBUG" -ge "$level" ]; then
        echo "$msg"
    fi
}

append_if_missing() {
    file=$1
    line=$2

    if ! grep -Fxq "$line" "$file" 2>/dev/null; then
        echo "$line" >> "$file"
    fi
}

CONFIG_PATH=/data/options.json

# Convert integer configs to boolean, to avoid a breaking old configs
declare -r bool_configs=( hide_ssid client_internet_access dhcp )
for i in "${bool_configs[@]}"; do
    config_value=$(bashio::config "$i")
    if bashio::config.true "$i" || bashio::config.false "$i"; then
        continue
    elif [ "$config_value" -eq 0 ]; then
        bashio::addon.option "$i" false
    else
        bashio::addon.option "$i" true
    fi
done

SSID=$(bashio::config "ssid")
WPA_PASSPHRASE=$(bashio::config "wpa_passphrase")
CHANNEL=$(bashio::config "channel")
ADDRESS=$(bashio::config "address")
NETMASK=$(bashio::config "netmask")
BROADCAST=$(bashio::config "broadcast")
INTERFACE=$(bashio::config "interface")
UPSTREAM_INTERFACE=$(bashio::config "upstream_interface" "")
BRIDGE_INTERFACE=$(bashio::config "bridge_interface" "br-ap")
HIDE_SSID=$(bashio::config.false "hide_ssid"; echo $?)
DHCP=$(bashio::config.false "dhcp"; echo $?)
DHCP_START_ADDR=$(bashio::config "dhcp_start_addr" )
DHCP_END_ADDR=$(bashio::config "dhcp_end_addr" )

ALLOW_MAC_ADDRESSES=$(bashio::config 'allow_mac_addresses' )
DENY_MAC_ADDRESSES=$(bashio::config 'deny_mac_addresses' )
DEBUG=$(bashio::config 'debug' )
HT_CAPAB=$(bashio::config 'ht_capab' '[HT40][SHORT-GI-20][DSSS_CCK-40]')
HOSTAPD_CONFIG_OVERRIDE=$(bashio::config 'hostapd_config_override' )
CLIENT_INTERNET_ACCESS=$(bashio::config.false 'client_internet_access'; echo $?)
CLIENT_DNS_OVERRIDE=$(bashio::config 'client_dns_override' )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )

# Requested mode matrix:
# - bridge mode only when client_internet_access=true and dhcp=false
# - all other combinations use own subnet mode
BRIDGE_MODE=false
if bashio::config.true "client_internet_access" && ! bashio::config.true "dhcp"; then
    BRIDGE_MODE=true
fi

# Enforces required env variables before applying any network changes
required_vars=(ssid wpa_passphrase channel interface)
for required_var in "${required_vars[@]}"; do
    bashio::config.require "$required_var" "An AP cannot be created without this information"
done

if [ "$BRIDGE_MODE" != "true" ]; then
    for required_var in address netmask broadcast; do
        bashio::config.require "$required_var" "Own subnet mode requires address, netmask and broadcast"
    done
fi

if [ "${#WPA_PASSPHRASE}" -lt 8 ]; then
    bashio::exit.nok "The WPA password must be at least 8 characters long!"
fi

route_interface_for_target() {
    target=$1

    if [ -z "$target" ]; then
        return 1
    fi

    ip route get "$target" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}'
}

gateway_for_interface() {
    iface=$1
    
    if [ -z "$iface" ]; then
        return 1
    fi
    
    # Try to find a gateway on this specific interface
    ip route show dev "$iface" 2>/dev/null | awk '/^default/ { print $3; exit }'
}

DEFAULT_GATEWAY=$(ip route show default | awk '/^default/ { print $3; exit }')
DEFAULT_ROUTE_INTERFACE=$(ip route show default | awk '/^default/ { print $5; exit }')
ROUTE_TARGET="$DEFAULT_GATEWAY"

# Allow explicit upstream interface override from configuration.
if [ -n "$UPSTREAM_INTERFACE" ]; then
    ROUTE_INTERFACE="$UPSTREAM_INTERFACE"
    # Override gateway if the configured interface has its own gateway
    INTERFACE_GATEWAY=$(gateway_for_interface "$UPSTREAM_INTERFACE")
    if [ -n "$INTERFACE_GATEWAY" ]; then
        DEFAULT_GATEWAY="$INTERFACE_GATEWAY"
        logger "Detected gateway on configured upstream interface $UPSTREAM_INTERFACE: $INTERFACE_GATEWAY" 1
    fi
elif [ -n "$ROUTE_TARGET" ]; then
    ROUTE_INTERFACE=$(route_interface_for_target "$ROUTE_TARGET")
else
    ROUTE_INTERFACE="$DEFAULT_ROUTE_INTERFACE"
fi

if [ -z "$ROUTE_INTERFACE" ]; then
    ROUTE_INTERFACE="$DEFAULT_ROUTE_INTERFACE"
fi

if [ -z "$ROUTE_INTERFACE" ] && ([ "$BRIDGE_MODE" = "true" ] || bashio::config.true "client_internet_access"); then
    bashio::exit.nok "Unable to determine upstream interface from host routing table."
fi

# Validate that the resolved upstream interface actually exists BEFORE any bridge/transparent setup
if [ -n "$ROUTE_INTERFACE" ] && ! ip link show "$ROUTE_INTERFACE" >/dev/null 2>&1; then
    if [ -n "$UPSTREAM_INTERFACE" ]; then
        bashio::exit.nok "Configured upstream_interface '$UPSTREAM_INTERFACE' does not exist. Available interfaces: $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
    else
        bashio::exit.nok "Resolved upstream interface '$ROUTE_INTERFACE' does not exist on this host."
    fi
fi

# iptables interface matching does not accept '.' in interface names (e.g. vlan subinterfaces like eth0.20).
# Convert such names to a '+' wildcard (eth0+) so rules can be applied safely.
IPTABLES_ROUTE_INTERFACE="$ROUTE_INTERFACE"
if [ -n "$IPTABLES_ROUTE_INTERFACE" ] && [[ "$IPTABLES_ROUTE_INTERFACE" == *.* ]]; then
    IPTABLES_ROUTE_INTERFACE="${IPTABLES_ROUTE_INTERFACE%%.*}+"
fi

logger "Detected default route interface: $DEFAULT_ROUTE_INTERFACE" 1
logger "Detected default gateway: $DEFAULT_GATEWAY" 1
if [ -n "$UPSTREAM_INTERFACE" ]; then
    logger "Using configured upstream interface override: $UPSTREAM_INTERFACE" 1
elif [ -n "$ROUTE_TARGET" ]; then
    logger "Resolved upstream interface via route target $ROUTE_TARGET: $ROUTE_INTERFACE" 1
fi
if [ "$ROUTE_INTERFACE" != "$IPTABLES_ROUTE_INTERFACE" ]; then
    logger "Using iptables-safe upstream matcher: $IPTABLES_ROUTE_INTERFACE" 1
fi
if [ -n "$BRIDGE_INTERFACE" ]; then
    logger "Online uplink device name: $BRIDGE_INTERFACE" 1
fi

echo "Starting Hass.io Access Point Addon"

# Setup interface
logger "# Setup interface:" 1
logger "Add to /etc/network/interfaces: iface $INTERFACE inet static" 1
# Create and add our interface to interfaces file
append_if_missing /etc/network/interfaces "iface $INTERFACE inet static"

logger "Run command: nmcli dev set $INTERFACE managed no" 1
nmcli dev set "$INTERFACE" managed no

logger "Run command: ip link set $INTERFACE down" 1
ip link set "$INTERFACE" down

if [ "$BRIDGE_MODE" = "true" ]; then
    logger "Bridge mode selected (client_internet_access=true && dhcp=false): upstream handles IP/DHCP." 1
    if [ -d "/sys/class/net/$ROUTE_INTERFACE/bridge" ]; then
        BRIDGE_DEVICE="$ROUTE_INTERFACE"
        logger "Using existing uplink device: $BRIDGE_DEVICE" 1
    else
        BRIDGE_DEVICE="$BRIDGE_INTERFACE"
        logger "Creating online uplink device: $BRIDGE_DEVICE" 1
        if ! ip link show "$BRIDGE_DEVICE" >/dev/null 2>&1; then
            ip link add name "$BRIDGE_DEVICE" type bridge
            CREATED_BRIDGE=true
        fi
        logger "Run command: ip link set $ROUTE_INTERFACE master $BRIDGE_DEVICE" 1
        ip link set "$ROUTE_INTERFACE" master "$BRIDGE_DEVICE"
    fi

    # Note: Do NOT add wireless interface to bridge here - hostapd will do it automatically
    # when configured with bridge= parameter. Adding it manually causes "RTNETLINK not supported" error.
    logger "Run command: ip link set $ROUTE_INTERFACE up" 1
    ip link set "$ROUTE_INTERFACE" up
    logger "Run command: ip link set $BRIDGE_DEVICE up" 1
    ip link set "$BRIDGE_DEVICE" up

    # In transparent bridge mode the Linux bridge forwards all L2 traffic (DHCP broadcasts,
    # ARP, etc.) natively without any NAT or relay. Clients appear directly on the upstream
    # network and receive IPs from the upstream DHCP server.
    # Do not set L3 addressing or routes here; upstream network remains authoritative.

    # In bridge mode, interface configuration is on the bridge, not the wireless interface
    # Hostapd will bring up the wireless interface and add it to the bridge automatically
    logger "Wireless interface will be configured by hostapd with bridge=$BRIDGE_DEVICE" 1
else
    logger "Own subnet mode selected: clients are isolated from upstream L2." 1
    logger "Add to /etc/network/interfaces: address $ADDRESS" 1
    append_if_missing /etc/network/interfaces "address $ADDRESS"
    logger "Add to /etc/network/interfaces: netmask $NETMASK" 1
    append_if_missing /etc/network/interfaces "netmask $NETMASK"
    logger "Add to /etc/network/interfaces: broadcast $BROADCAST" 1
    append_if_missing /etc/network/interfaces "broadcast $BROADCAST"

    logger "Run command: ip link set $INTERFACE up" 1
    ip link set "$INTERFACE" up
fi

# Setup signal handlers
trap 'term_handler' SIGTERM

# Build fresh service configuration files on each start.
: > /hostapd.conf
: > /dnsmasq.conf
: > /hostapd.allow
: > /hostapd.deny

# Setup hostapd.conf
logger "# Setup hostapd:" 1
logger "Add to hostapd.conf: ssid=$SSID" 1
echo "ssid=$SSID"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: wpa_passphrase=********" 1
echo "wpa_passphrase=$WPA_PASSPHRASE"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: channel=$CHANNEL" 1
echo "channel=$CHANNEL"'\n' >> /hostapd.conf
logger "Add to hostapd.conf: ignore_broadcast_ssid=$HIDE_SSID" 1
echo "ignore_broadcast_ssid=$HIDE_SSID"$'\n' >> /hostapd.conf
logger "Add to hostapd.conf: ht_capab=$HT_CAPAB" 1
echo "ht_capab=$HT_CAPAB"$'\n' >> /hostapd.conf

### MAC address filtering
## Allow is more restrictive, so we prioritise that and set
## macaddr_acl to 1, and add allowed MAC addresses to hostapd.allow
if [ ${#ALLOW_MAC_ADDRESSES} -ge 1 ]; then
    logger "Add to hostapd.conf: macaddr_acl=1" 1
    echo "macaddr_acl=1"$'\n' >> /hostapd.conf
    set -f
    ALLOWED=( $ALLOW_MAC_ADDRESSES )
    set +f
    logger "# Setup hostapd.allow:" 1
    logger "Allowed MAC addresses:" 0
    for mac in "${ALLOWED[@]}"; do
        echo "$mac"$'\n' >> /hostapd.allow
        logger "$mac" 0
    done
    logger "Add to hostapd.conf: accept_mac_file=/hostapd.allow" 1
    echo "accept_mac_file=/hostapd.allow"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, and add denied MAC addresses to hostapd.deny
elif [ ${#DENY_MAC_ADDRESSES} -ge 1 ]; then
        logger "Add to hostapd.conf: macaddr_acl=0" 1
        echo "macaddr_acl=0"$'\n' >> /hostapd.conf
    set -f
    DENIED=( $DENY_MAC_ADDRESSES )
    set +f
        logger "Denied MAC addresses:" 0
        for mac in "${DENIED[@]}"; do
            echo "$mac"$'\n' >> /hostapd.deny
            logger "$mac" 0
        done
        logger "Add to hostapd.conf: accept_mac_file=/hostapd.deny" 1
        echo "deny_mac_file=/hostapd.deny"$'\n' >> /hostapd.conf
## else set macaddr_acl to 0, with blank allow and deny files
else
    logger "Add to hostapd.conf: macaddr_acl=0" 1
    echo "macaddr_acl=0"$'\n' >> /hostapd.conf
fi


# Set address for the selected interface or bridge.
if [ "$BRIDGE_MODE" = "true" ]; then
    # In AP mode the IP is already set on the bridge device above
    logger "Bridge IP address already configured: $ADDRESS" 1
else
    ifconfig "$INTERFACE" "$ADDRESS" netmask "$NETMASK" broadcast "$BROADCAST"
fi

# Add interface to hostapd.conf
logger "Add to hostapd.conf: interface=$INTERFACE" 1
echo "interface=$INTERFACE"$'\n' >> /hostapd.conf

if [ "$BRIDGE_MODE" = "true" ]; then
    logger "Add to hostapd.conf: bridge=$BRIDGE_DEVICE" 1
    echo "bridge=$BRIDGE_DEVICE"$'\n' >> /hostapd.conf
fi

# Append override options to hostapd.conf
if [ ${#HOSTAPD_CONFIG_OVERRIDE} -ge 1 ]; then
    logger "# Custom hostapd config options:" 0
    set -f
    HOSTAPD_OVERRIDES=( $HOSTAPD_CONFIG_OVERRIDE )
    set +f
    for override in "${HOSTAPD_OVERRIDES[@]}"; do
        echo "$override"$'\n' >> /hostapd.conf
        logger "Add to hostapd.conf: $override" 0
    done
fi

# Setup dnsmasq.conf if DHCP is enabled in config
if [ "$BRIDGE_MODE" != "true" ] && bashio::config.true "dhcp"; then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
    echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
    logger "Add to dnsmasq.conf: interface=$INTERFACE" 1
    echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf

    ## DNS
    dns_array=()
    if [ ${#CLIENT_DNS_OVERRIDE} -ge 1 ]; then
        dns_string="dhcp-option=6"
        set -f
        DNS_OVERRIDES=( $CLIENT_DNS_OVERRIDE )
        set +f
        for override in "${DNS_OVERRIDES[@]}"; do
            dns_string+=",$override"
        done
        echo "$dns_string"$'\n' >> /dnsmasq.conf
        logger "Add custom DNS: $dns_string" 0
    else
        IFS=$'\n' read -r -d '' -a dns_array < <( nmcli device show | grep IP4.DNS | awk '{print $2}' && printf '\0' )

        if [ ${#dns_array[@]} -eq 0 ]; then
            logger "Couldn't get DNS servers from host. Consider setting with 'client_dns_override' config option." 0
        else
            dns_string="dhcp-option=6"
            for dns_entry in "${dns_array[@]}"; do
                dns_string+=",$dns_entry"
            done
            echo "$dns_string"$'\n' >> /dnsmasq.conf
            logger "Add DNS: $dns_string" 0
        fi
    fi

    # Append override options to dnsmasq.conf
    if [ ${#DNSMASQ_CONFIG_OVERRIDE} -ge 1 ]; then
        logger "# Custom dnsmasq config options:" 0
        set -f
        DNSMASQ_OVERRIDES=( $DNSMASQ_CONFIG_OVERRIDE )
        set +f
        for override in "${DNSMASQ_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> /dnsmasq.conf
            logger "Add to dnsmasq.conf: $override" 0
        done
    fi
else
    if [ "$BRIDGE_MODE" = "true" ]; then
        # Bridge mode: upstream handles DHCP, local server stays off unless explicitly overridden.
        logger "# Bridge mode: DHCP handled by upstream, skipping local DHCP server" 1
    fi

    if [ "$BRIDGE_MODE" = "true" ] && [ ${#DNSMASQ_CONFIG_OVERRIDE} -ge 1 ]; then
        logger "# Custom dnsmasq config options detected - starting dnsmasq" 0
        set -f
        DNSMASQ_OVERRIDES=( $DNSMASQ_CONFIG_OVERRIDE )
        set +f
        for override in "${DNSMASQ_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> /dnsmasq.conf
            logger "Add to dnsmasq.conf: $override" 0
        done
        START_DNSMASQ_IN_AP_MODE=true
    else
        START_DNSMASQ_IN_AP_MODE=false
    fi
fi

is_masquerading_enabled() {
    if [ -z "$IPTABLES_ROUTE_INTERFACE" ]; then
        return 1
    fi
    iptables-nft -t nat -C POSTROUTING -o "$IPTABLES_ROUTE_INTERFACE" -j MASQUERADE -m comment --comment "ap-addon-inet" 2>/dev/null
}

is_forwarding_enabled() {
    if [ -z "$IPTABLES_ROUTE_INTERFACE" ]; then
        return 1
    fi
    iptables-nft -C FORWARD -i "$INTERFACE" -o "$IPTABLES_ROUTE_INTERFACE" -j ACCEPT -m comment --comment "ap-addon-inet" 2>/dev/null
}

if [ "$BRIDGE_MODE" != "true" ] && bashio::config.true "client_internet_access"; then
        ## Add masquerade if not already present
        if ! is_masquerading_enabled; then
            iptables-nft -t nat -A POSTROUTING -o "$IPTABLES_ROUTE_INTERFACE" -j MASQUERADE -m comment --comment "ap-addon-inet"
        fi

    ## Allow forwarding if not already allowed
    if ! is_forwarding_enabled; then
        iptables-nft -A FORWARD -i "$INTERFACE" -o "$IPTABLES_ROUTE_INTERFACE" -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -A FORWARD -i "$IPTABLES_ROUTE_INTERFACE" -o "$INTERFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
else
    ## Remove masquerade if present
    if is_masquerading_enabled; then
        iptables-nft -t nat -D POSTROUTING -o "$IPTABLES_ROUTE_INTERFACE" -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Remove forwarding if present
    if is_forwarding_enabled; then
        iptables-nft -D FORWARD -i "$INTERFACE" -o "$IPTABLES_ROUTE_INTERFACE" -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -D FORWARD -i "$IPTABLES_ROUTE_INTERFACE" -o "$INTERFACE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
fi

# Start dnsmasq if DHCP is enabled in config or relay server is configured.
# In transparent mode, only start if custom config is provided.
if bashio::config.true "dhcp" || [ "${START_DNSMASQ_IN_AP_MODE:-false}" = "true" ]; then
    logger "## Starting dnsmasq daemon" 1
    dnsmasq -C /dnsmasq.conf
else
    logger "## Skipping dnsmasq - transparent bridge mode with no custom DNS config" 1
fi

logger "## Starting hostapd daemon" 1
# If debug level is greater than 1, start hostapd in debug mode
if [ "$DEBUG" -gt 1 ]; then
    hostapd -d /hostapd.conf & wait ${!}
else
    hostapd /hostapd.conf & wait ${!}
fi
