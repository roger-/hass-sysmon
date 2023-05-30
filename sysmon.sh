#!/bin/sh
# sysmon.sh v0.32

# Home Assistant configuration defaults (can be overwritten in .config file)
HASS_TOKEN=""
HASS_SERVER="homeassistant.local"
HASS_PORT="8123"
HASS_MQTT_PREFIX="homeassistant"

# MQTT path to publish states
MQTT_PUB_PATH="/home/servers"
MQTT_PUBLISH_PERIOD=20

# Define sensor prefix. Options: 0 = none (default and if not 1 or string), 1 = hostname, custom if string
SENSOR_PREFIX_OPTION=0

# name of network interface (e.g. eth0) otherwise first active one will be used
NETWORK_IFACE=""

# debug levels: 0 = DEBUG, 1 = INFO, 2 = WARN, 3 = ERROR
DEBUG_LEVEL=1

# how long to wait for the Home Assistant server to respond (or to sleep if wait not supported)
TIMEOUT_SERVER=1

# sensor config
ENABLE_DISK=1
ENABLE_LOAD=1
ENABLE_MEMORY=1
ENABLE_SWAP=1
ENABLE_DISK=1
ENABLE_WIFI=1
ENABLE_UPTIME=1
ENABLE_TEMPERATURE=1
ENABLE_PING=1
ENABLE_TOP_CPU=0

CONFIG_PING_HOST="192.168.1.1"

CONFIG_TOP_CPU_IGNORE_COMMAND="top"
CONFIG_TOP_CPU_MAX=3

##### Logging functions #####

COLOR_RESET="\033[0m"
COLOR_RED="\033[31;1m"
COLOR_GREEN="\033[32;1m"
COLOR_BLUE="\033[33;1m"
COLOR_GRAY="\033[37;1m"

error() {
    if [ $DEBUG_LEVEL -le 3 ]; then
        printf '%b' "${COLOR_RED}ERROR:${COLOR_RESET} $@\n"
    fi
}

warning() {
    if [ $DEBUG_LEVEL -le 2 ]; then
        printf '%b' "${COLOR_BLUE}WARNING:${COLOR_RESET} $@\n"
    fi
}

info() {
    if [ $DEBUG_LEVEL -le 1 ]; then
        printf '%b' "${COLOR_GREEN}INFO:${COLOR_RESET} $@\n"
    fi
}

debug() {
    if [ $DEBUG_LEVEL -le 0 ]; then
        printf '%b' "${COLOR_GRAY}DEBUG:${COLOR_RESET} $@\n"
    fi
}

##### Helper functions #####

cmd_exists() {
  command -v "$1" 2>&1 >/dev/null
}

beginswith() {
    case "$2" in "$1"*) true;; *) false;; esac;
}

print_key_vals() {
    echo -n "\"$1\":$2"
    shift 2

    while [ $# -ge 2 ]; do
        echo -n ",\"$1\":$2"
        shift 2
    done
}

print_json() {
    echo -n "{$(print_key_vals "$@")}"
}

deref_path_symlink() {
    echo $(cd "$*" && pwd -P)
}

macid() {
    nic_name=$1

    cat /sys/class/net/$nic_name/address | head -n 1 | sed 's/://g'
}

active_nic() {
    for nic_path in /sys/class/net/*; do
        nic_name=$(basename "$nic_path")
        is_virtual=$(deref_path_symlink "$nic_path" | grep virtual)

        # skip possibly virtual or inactive devices 
        if [ -z "$is_virtual" ] && [ "$(cat $nic_path/operstate)" = "up" ]; then 
            echo "$nic_name"
            return 0
        fi
    done

    return 1
}

temperature_sensor_names() {
    if ! ls /sys/class/thermal/thermal_zone* > /dev/null 2>&1; then
        return
    fi

    for tz in /sys/class/thermal/thermal_zone*; do
        cat "$tz"/type | sed 's/-/_/'
    done
}

##### Sensor functions #####

CPU_COUNT=$(grep -c ^processor /proc/cpuinfo)

avg_load() {
    loadavg=$(cat /proc/loadavg)

    avg_load_1min_pc=$(echo $loadavg | awk '{printf 100 * $1 / '$CPU_COUNT'}')
    avg_load_5min_pc=$(echo $loadavg | awk '{printf 100 * $2 / '$CPU_COUNT'}')
    avg_load_10min_pc=$(echo $loadavg | awk '{printf 100 * $3 / '$CPU_COUNT'}')

    print_key_vals \
        avg_load_1min_pc $avg_load_1min_pc \
        avg_load_5min_pc $avg_load_5min_pc \
        avg_load_10min_pc $avg_load_10min_pc
}

top_cpu() {
    field_ind_to_name="$(top -bn1 | grep -E  '^ +PID' | sed 's/\s\s*/\n/g' |tail -n +2| grep -nx ".*")"

    cpu_ind=$(echo "$field_ind_to_name" | grep "%CPU" | cut -d: -f1)
    command_ind=$(echo "$field_ind_to_name" | grep "COMMAND" | cut -d: -f1)

    # below assumes COMMAND is last column and PID is first
    top_commands=$(top -bn1 | sed -n '/\s*PID.*$/,$p' | tail -n +2 | sed 's/\s\s*/ /g' | sed 's/^\s*//g' | cut -d' ' -f"${cpu_ind},${command_ind}-")

    i=1
    did_print=0

    echo "$top_commands" | while read line; do
        cpu_pc=$(echo $line | cut -d' ' -f1 | awk '{printf $1 / '$CPU_COUNT'}')
        command_name=$(echo $line | cut -d' ' -f2-)

        # ignore given command 
        if [ ! -z "$CONFIG_TOP_CPU_IGNORE_COMMAND" ] && (beginswith "$command_name" "$CONFIG_TOP_CPU_IGNORE_COMMAND"); then
            continue
        fi

        if [ $did_print -eq 1 ]; then
            echo -n ","
        fi
        did_print=1

        print_key_vals \
            "top_${i}_command_name"   "\"$command_name\"" \
            "top_${i}_command_cpu_pc" "$cpu_pc"

        if [ $i -ge $CONFIG_TOP_CPU_MAX ]; then
            return
        fi

        i=$((i+1))
    done
}

uptime_duration() {
    uptime_sec=$(awk '{print $1}' /proc/uptime)

    print_key_vals uptime_sec $uptime_sec
}

disk_usage() {
    root_usage=$(df | grep " /$")

    disk_free_Kb=$(echo $root_usage | awk '{print $4}')
    disk_used_pc=$(echo $root_usage | awk '{print 100 * $3 / $2}')

    print_key_vals \
        disk_free_kb $disk_free_Kb \
        disk_used_pc $disk_used_pc
}

wifi_signal() {
    signal=$(awk '/wlp/ || /wlan0/ { print $0; exit}' /proc/net/wireless)

    wifi_link_pc=$(echo $signal | awk '{printf "%d", $3}')
    wifi_level_dbm=$(echo $signal | awk '{printf "%d", $4}')

    print_key_vals \
        wifi_link_pc $wifi_link_pc \
        wifi_level_dbm $wifi_level_dbm
}

temperature() {
    if ! ls /sys/class/thermal/thermal_zone* > /dev/null 2>&1; then
        return 1
    fi

    sep=""
    for tz in /sys/class/thermal/thermal_zone*; do
        sensor_name="temperature_$(cat $tz/type | sed 's/-/_/')_C"
        temp=$(awk '{printf $1 / 1000}' $tz/temp)

        echo -n "$sep"
        sep=","
        print_key_vals $sensor_name $temp
    done
}

memory_usage() {
    mem=$(cat /proc/meminfo)

    mem_free_kB=$(echo "$mem" | grep MemAvailable | awk '{printf $2}')
    mem_used_pc=$(echo "$mem" | grep MemTotal | awk '{printf 100 * ($2 - '$mem_free_kB') / $2}')

    print_key_vals \
        mem_free_kB $mem_free_kB \
        mem_used_pc $mem_used_pc
}

swap_usage() {
    mem=$(cat /proc/meminfo)

    swap_total_kB=$(echo "$mem" | grep SwapTotal | awk '{printf $2}')

    # check if no swap
    if [ $swap_total_kB -eq 0 ]; then
        return 1
    fi

    swap_free_kB=$(echo "$mem" | grep SwapFree | awk '{printf $2}')
    swap_used_pc=$(echo | awk '{printf 100 * ('$swap_total_kB' - '$swap_free_kB') / '$swap_total_kB'}') 

    print_key_vals \
        swap_free_kB $swap_free_kB \
        swap_used_pc $swap_used_pc
}

host_name() {
    print_key_vals host_name \"$(cat /proc/sys/kernel/hostname)\"
}

ping_host() {
    result="$(ping $CONFIG_PING_HOST -q -c 1 -W 1)"
    retval=$?

    if ! [ $retval -eq 0 ]; then
        info ping $CONFIG_PING_HOST failed: $(echo "$result" | tail -n 1)
        return 1
    fi

    rtt=$(echo $result | tail -n 1 | cut -d= -f2 | cut -d\/ -f 1 | tr -d ' ')
    print_key_vals ping_rtt_ms $rtt
}

##### Core network functions #####

HTTP_HEADER_CTYPE="Content-Type: application/json"

HTTP_PATH_SENSOR="/api/states/sensor"
HTTP_PATH_MQTT="/api/services/mqtt/publish"

post_json_message_curl() {
    path="$1"
    json="$2"

    url="http://${HASS_SERVER}:${HASS_PORT}${path}"

    response=$(curl -m $TIMEOUT_SERVER -s -X POST -w "\\n%{http_code}\\n" -H "$HTTP_HEADER_AUTH" -H "$HTTP_HEADER_CTYPE" -d "$json" "$url")
    http_code=$(echo "$response" | tail -n 1)

    if [ "$http_code" != "200" ]; then
        debug "sent JSON: $json"
        error "received HTTP code $http_code, full response:"
        printf '%b' "$response" | head -n-1
    else
        debug "message receipt confirmed"
    fi
}

post_json_message_netcat() {
    path="$1"
    json="$2"

    data="POST $path HTTP/1.1\r
$HTTP_HEADER_AUTH\r
$HTTP_HEADER_CTYPE\r
Content-Length: ${#json}\r
\r
"
    data="${data}${json}"

    response=$(printf '%b' "$data" | eval "$NETCAT_CMD $HASS_SERVER $HASS_PORT" 2>&1)
    sleep $TIMEOUT_SERVER

    http_code=$(echo "$response" | awk '/^HTTP/{print $2; exit}')

    if [ ! $http_code ]; then
        info "message receipt not confirmed"
        return
    fi

    if [ "$http_code" != "200" ]; then
        debug "sent JSON: $json"
        error "received HTTP code $http_code, full response:"
        printf '%b' "$response"
    else
        debug "message receipt confirmed"
    fi
}

##### Network helper functions #####

post_json_message() {
    if [ $HAS_CURL -eq 1 ]; then
        post_json_message_curl "$1" "$2"
    else
        post_json_message_netcat "$1" "$2"
    fi
}

post_sensor_state() {
    path="$HTTP_PATH_SENSOR.$1"
    json="$2"

    post_json_message "$path" "$json"
}

post_mqtt() {
    topic="$1"
    json_str=$(echo "$2" | sed 's/"/\\"/g')
    msg=$(print_json topic \"$topic\" payload "\"$json_str\"" retain true)

    post_json_message "$HTTP_PATH_MQTT" "$msg"
}

##### Auto-discovery and state publishing functions #####

publish_state_loop() {
    info "publishing state to topic $STATE_TOPIC every $MQTT_PUBLISH_PERIOD s"

    time_pub_next=$(date +"%s")

    while true
    do
        time_now=$(date +"%s")
        time_sleep=$(( $time_pub_next - $time_now ))

        if [ $time_sleep -gt 0 ]; then
            debug "sleeping for $time_sleep s"
            sleep $time_sleep
        fi

        time_pub_next=$(( $time_pub_next + $MQTT_PUBLISH_PERIOD))

        data="$(host_name)"
        [ $ENABLE_MEMORY      -eq 1 ] && val=$(memory_usage)    && data="${data},$val"
        [ $ENABLE_SWAP        -eq 1 ] && val=$(swap_usage)      && data="${data},$val"
        [ $ENABLE_DISK        -eq 1 ] && val=$(disk_usage)      && data="${data},$val"
        [ $ENABLE_LOAD        -eq 1 ] && val=$(avg_load)        && data="${data},$val"
        [ $ENABLE_WIFI        -eq 1 ] && val=$(wifi_signal)     && data="${data},$val"
        [ $ENABLE_UPTIME      -eq 1 ] && val=$(uptime_duration) && data="${data},$val"
        [ $ENABLE_PING        -eq 1 ] && val=$(ping_host)       && data="${data},$val"
        [ $ENABLE_TEMPERATURE -eq 1 ] && val=$(temperature)     && data="${data},$val"
        [ $ENABLE_TOP_CPU     -eq 1 ] && val=$(top_cpu)         && data="${data},$val"

        json="{${data}}"

        debug "publishing state message"
        post_mqtt "$STATE_TOPIC" "$json"
    done
}

publish_discovery_sensor() {
    param="$1"
    name="$2"
    unit_of_measurement="$3"
    device_class="$4"

    config_topic="$HASS_MQTT_PREFIX/sensor/$DEVICE_NAME/$param/config"

    device_name="System statistics $DEVICE_NAME"
    version="$(uname -a)"
    device=$(print_json identifiers '["'"$DEVICE_NAME"'"]' name "\"$device_name\"" sw_version "\"$version\"")

    msg=$(print_key_vals name "\"$name\"")
    msg=$msg,$(print_key_vals state_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals json_attributes_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals expire_after \"$((5 * $MQTT_PUBLISH_PERIOD))\")
    msg=$msg,$(print_key_vals value_template "\"{{ value_json.${param} }}\"")
    msg=$msg,$(print_key_vals unique_id \"$DEVICE_NAME-$param\")
    msg=$msg,$(print_key_vals device "$device")
    [ $device_class ]        && msg="$msg,$(print_key_vals device_class \"$device_class\")"
    [ $unit_of_measurement ] && msg=$msg,$(print_key_vals unit_of_measurement \"$unit_of_measurement\")

    msg={$msg}

    debug "sending discovery message for state $param"
    post_mqtt "$config_topic" "$msg"
}

publish_discovery_all() {
    info "sending discovery messages"

    [ $ENABLE_UPTIME -eq 1 ] && publish_discovery_sensor uptime_sec "${SENSOR_PREFIX} Uptime" "s" "duration"

    [ $ENABLE_PING   -eq 1 ] && publish_discovery_sensor ping_rtt_ms "${SENSOR_PREFIX} Ping RTT" "ms" "duration"    

    [ $ENABLE_LOAD   -eq 1 ] && publish_discovery_sensor avg_load_1min_pc "${SENSOR_PREFIX} CPU load (1 min avg)" "%"
    [ $ENABLE_LOAD   -eq 1 ] && publish_discovery_sensor avg_load_5min_pc "${SENSOR_PREFIX} CPU load (5 min avg)" "%"
    [ $ENABLE_LOAD   -eq 1 ] && publish_discovery_sensor avg_load_10min_pc "${SENSOR_PREFIX} CPU load (10 min avg)" "%"

    [ $ENABLE_MEMORY -eq 1 ] && publish_discovery_sensor mem_free_kB "${SENSOR_PREFIX} Memory free" "kB"
    [ $ENABLE_MEMORY -eq 1 ] && publish_discovery_sensor mem_used_pc "${SENSOR_PREFIX} Memory used" "%"

    [ $ENABLE_SWAP   -eq 1 ] && publish_discovery_sensor swap_free_kB "${SENSOR_PREFIX} Swap free" "kB"
    [ $ENABLE_SWAP   -eq 1 ] && publish_discovery_sensor swap_used_pc "${SENSOR_PREFIX} Swap used" "%"

    [ $ENABLE_WIFI   -eq 1 ] && publish_discovery_sensor wifi_link_pc "${SENSOR_PREFIX} WiFi link" "%"
    [ $ENABLE_WIFI   -eq 1 ] && publish_discovery_sensor wifi_level_dbm "${SENSOR_PREFIX} WiFi level" "dBm" "signal_strength"

    [ $ENABLE_DISK   -eq 1 ] && publish_discovery_sensor disk_free_kb "${SENSOR_PREFIX} Disk free" "kB"
    [ $ENABLE_DISK   -eq 1 ] && publish_discovery_sensor disk_used_pc "${SENSOR_PREFIX} Disk used" "%"

    if [ $ENABLE_TOP_CPU -eq 1 ]; then
        i=1
        while [ $i -le $CONFIG_TOP_CPU_MAX ]; do
            publish_discovery_sensor top_${i}_command_cpu_pc "${SENSOR_PREFIX} Top $i command CPU load" "%"
            publish_discovery_sensor top_${i}_command_name "${SENSOR_PREFIX} Top $i command name" ""

            i=$(($i+1))
        done
    fi

    if [ $ENABLE_TEMPERATURE -eq 1 ]; then
        for sensor_name in $(temperature_sensor_names); do        
            var_name="temperature_${sensor_name}_C"
            sensor_name=$(echo $sensor_name | sed 's/_temp$//' | sed 's/_/ /')

            publish_discovery_sensor $var_name "${SENSOR_PREFIX} Temperature $sensor_name" "°C" "temperature"
        done
    fi
}

##### main #####

setup() {
    config_file_name="$(basename $0 .sh).config"
    config_path_full="${PATH_CONFIG}/${config_file_name}"

    if [ -f "$config_path_full" ]; then
        info "loading config from $config_path_full"
        . "$config_path_full"
    fi

    # need to set this here in case token gets loaded from file
    HTTP_HEADER_AUTH="Authorization: Bearer $HASS_TOKEN"

    if cmd_exists curl; then
        HAS_CURL=1
        debug  "using curl"
        return 0
    elif cmd_exists netcat; then
        HAS_NETCAT=1
        NETCAT_CMD="netcat"
        debug "using netcat"
    elif cmd_exists nc; then
        HAS_NETCAT=1
        NETCAT_CMD="nc"
        debug "using nc"
    else
        error "missing curl and netcat/nc, please install one"
        exit 1
    fi

    if ( $NETCAT_CMD 2>&1 | grep "\-w" > /dev/null ); then
        debug "netcat supports delay parameter"
        NETCAT_CMD="$NETCAT_CMD -w $TIMEOUT_SERVER"
        TIMEOUT_SERVER=0
    else
        warning "netcat does not support delay parameter (-w), messages may not be reliably sent and confirmed"
        HAS_NETCAT_BASIC=1
    fi
}

start() {
    HAS_CURL=0
    HAS_NETCAT=0
    HAS_NETCAT_BASIC=0
    NETCAT_CMD="netcat"

    # figure out MAC address on given interface, or first active one found
    [ -z "$NETWORK_IFACE" ] && NETWORK_IFACE=$(active_nic)
    MAC_ID="$(macid $NETWORK_IFACE)"
    if [ -z "$MAC_ID" ]; then
        error "couldn't determine MAC address, is interface up?"
        exit 1
    fi

    DEVICE_NAME="$MAC_ID-$(cat /proc/sys/kernel/hostname)"
    STATE_TOPIC="$MQTT_PUB_PATH/$DEVICE_NAME/state"

    info "using device name: $DEVICE_NAME"
    
    sensor_prefix_generator
    if ! [ -z "$SENSOR_PREFIX" ]; then
        info "using sensor prefix: $SENSOR_PREFIX"
    fi

    setup
    publish_discovery_all

    # HACK: send discovery twice to improve chances with basic netcat
    if [ $HAS_NETCAT_BASIC -eq 1 ]; then
        info "discovery messages may not have been delivered, resending"
        publish_discovery_all
    fi

    publish_state_loop
}

# determine where to load config -- first parameter or script directory
if [ ! -z "$1" ]; then
    PATH_CONFIG="$1"
else
    PATH_CONFIG="$(dirname $0)"
fi

start
