#!/usr/bin/with-contenv bashio

# SIGTERM-handler this funciton will be executed when the container receives the SIGTERM signal (when stopping)
term_handler(){
	logger "Stopping Hass.io Access Point" 0
	ifdown $INTERFACE
	ip link set $INTERFACE down
	ip addr flush dev $INTERFACE
	exit 0
}

# Logging function to set verbosity of output to addon log
logger(){
    msg=$1
    level=$2
    if [ $DEBUG -ge $level ]; then
        echo $msg
    fi
}

CONFIG_PATH=/data/options.json

# Convert integer configs to boolean, to avoid a breaking old configs
declare -r bool_configs=( hide_ssid client_internet_access dhcp )
for i in $bool_configs ; do
    if bashio::config.true $i || bashio::config.false $i ; then
        continue
    elif [ $config_value -eq 0 ] ; then
        bashio::addon.option $config_value false
    else
        bashio::addon.option $config_value true
    fi
done

SSID=$(bashio::config "ssid")
WPA_PASSPHRASE=$(bashio::config "wpa_passphrase")
CHANNEL=$(bashio::config "channel")
ADDRESS=$(bashio::config "address")
NETMASK=$(bashio::config "netmask")
BROADCAST=$(bashio::config "broadcast")
INTERFACE=$(bashio::config "interface")
HIDE_SSID=$(bashio::config.false "hide_ssid"; echo $?)
DHCP=$(bashio::config.false "dhcp"; echo $?)
DHCP_START_ADDR=$(bashio::config "dhcp_start_addr" )
DHCP_END_ADDR=$(bashio::config "dhcp_end_addr" )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )
ALLOW_MAC_ADDRESSES=$(bashio::config 'allow_mac_addresses' )
DENY_MAC_ADDRESSES=$(bashio::config 'deny_mac_addresses' )
DENY_MAC_INTERNET=$(bashio::config 'deny_mac_internet' )
DEBUG=$(bashio::config 'debug' )
HT_CAPAB=$(bashio::config 'ht_capab' '[HT40][SHORT-GI-20][DSSS_CCK-40]')
HOSTAPD_CONFIG_OVERRIDE=$(bashio::config 'hostapd_config_override' )
CLIENT_INTERNET_ACCESS=$(bashio::config.false 'client_internet_access'; echo $?)
CLIENT_DNS_OVERRIDE=$(bashio::config 'client_dns_override' )
DNSMASQ_CONFIG_OVERRIDE=$(bashio::config 'dnsmasq_config_override' )

# Get the Default Route interface
DEFAULT_ROUTE_INTERFACE=$(ip route show default | awk '/^default/ { print $5 }')

echo "Starting Hass.io Access Point Addon"

# Setup interface
logger "# Setup interface:" 1
logger "Add to /etc/network/interfaces: iface $INTERFACE inet static" 1
# Create and add our interface to interfaces file
echo "iface $INTERFACE inet static"$'\n' >> /etc/network/interfaces

logger "Run command: nmcli dev set $INTERFACE managed no" 1
nmcli dev set $INTERFACE managed no

logger "Run command: ip link set $INTERFACE down" 1
ip link set $INTERFACE down

logger "Add to /etc/network/interfaces: address $ADDRESS" 1
echo "address $ADDRESS"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: netmask $NETMASK" 1
echo "netmask $NETMASK"$'\n' >> /etc/network/interfaces
logger "Add to /etc/network/interfaces: broadcast $BROADCAST" 1
echo "broadcast $BROADCAST"$'\n' >> /etc/network/interfaces

logger "Run command: ip link set $INTERFACE up" 1
ip link set $INTERFACE up

# Setup signal handlers
trap 'term_handler' SIGTERM

# Enforces required env variables
required_vars=(ssid wpa_passphrase channel address netmask broadcast)
for required_var in "${required_vars[@]}"; do
    bashio::config.require $required_var "An AP cannot be created without this information"
done

if [ ${#WPA_PASSPHRASE} -lt 8 ] ; then
    bashio::exit.nok "The WPA password must be at least 8 characters long!"
fi

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
    ALLOWED=($ALLOW_MAC_ADDRESSES)
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
        DENIED=($DENY_MAC_ADDRESSES)
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


# Set address for the selected interface. Not sure why this is now not being set via /etc/network/interfaces, but maybe interfaces file is no longer required...
ifconfig $INTERFACE $ADDRESS netmask $NETMASK broadcast $BROADCAST

# Add interface to hostapd.conf
logger "Add to hostapd.conf: interface=$INTERFACE" 1
echo "interface=$INTERFACE"$'\n' >> /hostapd.conf

# Append override options to hostapd.conf
if [ ${#HOSTAPD_CONFIG_OVERRIDE} -ge 1 ]; then
    logger "# Custom hostapd config options:" 0
    HOSTAPD_OVERRIDES=($HOSTAPD_CONFIG_OVERRIDE)
    for override in "${HOSTAPD_OVERRIDES[@]}"; do
        echo "$override"$'\n' >> /hostapd.conf
        logger "Add to hostapd.conf: $override" 0
    done
fi

# Setup dnsmasq.conf if DHCP is enabled in config
if $(bashio::config.true "dhcp"); then
    logger "# DHCP enabled. Setup dnsmasq:" 1
    logger "Add to dnsmasq.conf: dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h" 1
        echo "dhcp-range=$DHCP_START_ADDR,$DHCP_END_ADDR,12h"$'\n' >> /dnsmasq.conf
        logger "Add to dnsmasq.conf: interface=$INTERFACE" 1
        echo "interface=$INTERFACE"$'\n' >> /dnsmasq.conf

    ## DNS
    dns_array=()
        if [ ${#CLIENT_DNS_OVERRIDE} -ge 1 ]; then
            dns_string="dhcp-option=6"
            DNS_OVERRIDES=($CLIENT_DNS_OVERRIDE)
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
        DNSMASQ_OVERRIDES=($DNSMASQ_CONFIG_OVERRIDE)
        for override in "${DNSMASQ_OVERRIDES[@]}"; do
            echo "$override"$'\n' >> /dnsmasq.conf
            logger "Add to dnsmasq.conf: $override" 0
        done
    fi
else
	logger "# DHCP not enabled. Skipping dnsmasq" 1
fi

is_masquerading_enabled() {
    iptables-nft -t nat -C POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet" 2>/dev/null
}

is_forwarding_enabled() {
    iptables-nft -C FORWARD -i $INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet" 2>/dev/null
}

# Setup Client Internet Access
if $(bashio::config.true "client_internet_access"); then
    ## Add masquerade if not already present
    if ! is_masquerading_enabled; then
        iptables-nft -t nat -A POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Allow forwarding if not already allowed
    if ! is_forwarding_enabled; then
        iptables-nft -A FORWARD -i $INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -A FORWARD -i $DEFAULT_ROUTE_INTERFACE -o $INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
else
    ## Remove masquerade if present
    if is_masquerading_enabled; then
        iptables-nft -t nat -D POSTROUTING -o $DEFAULT_ROUTE_INTERFACE -j MASQUERADE -m comment --comment "ap-addon-inet"
    fi

    ## Remove forwarding if present
    if is_forwarding_enabled; then
        iptables-nft -D FORWARD -i $INTERFACE -o $DEFAULT_ROUTE_INTERFACE -j ACCEPT -m comment --comment "ap-addon-inet"
        iptables-nft -D FORWARD -i $DEFAULT_ROUTE_INTERFACE -o $INTERFACE -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "ap-addon-inet"
    fi
fi

# jail feature testing: https://github.com/ex-ml/Hassio-Access-Point/issues/72
# blocks specific MAC addresses from accessing internet, but still allow them to connect to AP
# add rules with comment: ap-addon-block-inet - allow rules to be removed/readded
# while true; do
#     rule_num=$(iptables-nft -L FORWARD --line-numbers -n | grep "ap-addon-block-inet" | head -1 | awk '{print $1}')
#     if [ -z "$rule_num" ] || [ "$rule_num" = "num" ]; then
#         # "num" appears in the header line. If we match that there are 0 rules
#         break
#     fi
#     iptables-nft -D FORWARD "$rule_num" 2>/dev/null || break
# done

# if [ ${#DENY_MAC_INTERNET} -ge 1 ]; then
#     DENIED_INTERNET=($DENY_MAC_INTERNET)
#     logger "# Blocking MAC addresses from internet access:" 0
#     for mac in "${DENIED_INTERNET[@]}"; do
#         # insert (-I) to insert rule at beginning, so that DROPs are before ACCEPTs
#         # block traffic from specified MACs going from AP interface to inet int
#         iptables-nft -I FORWARD -i $INTERFACE -m mac --mac-source "$mac" -o $DEFAULT_ROUTE_INTERFACE -j DROP -m comment --comment "ap-addon-block-inet"
#         logger "Blocked MAC $mac from internet access" 0
#     done
# fi

# Start dnsmasq if DHCP is enabled in config
if $(bashio::config.true "dhcp"); then
    logger "## Starting dnsmasq daemon" 1
    dnsmasq -C /dnsmasq.conf
fi

logger "## Starting hostapd daemon" 1
# If debug level is greater than 1, start hostapd in debug mode
if [ $DEBUG -gt 1 ]; then
    hostapd -d /hostapd.conf & wait ${!}
else
    hostapd /hostapd.conf & wait ${!}
fi
