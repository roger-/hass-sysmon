#!/bin/sh
# sysmon.sh v0.2

# Home Assistant configuration defaults (can be overwritten in .config file)
HASS_TOKEN=""
HASS_SERVER="homeassistant.local"
HASS_PORT="8123"
HASS_MQTT_PREFIX="homeassistant"

# MQTT path to publish states
MQTT_PUB_PATH="/home/servers"
MQTT_PUBLISH_PERIOD=15

# name of network interface (e.g. eth0) otherwise first active one will be used
NETWORK_IFACE=""

# debug levels: 0 = DEBUG, 1 = INFO, 2 = WARN, 3 = ERROR
DEBUG_LEVEL=1

# how long to wait for the server to respond (or sleep if not supported)
TIMEOUT_SERVER=1

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

deref_path_symlink()
{
    echo $(cd "$*" && pwd -P)
}

macid()
{
    nic_name=$1

    # use nic if given
    if ! [ -z "$nic_name" ]; then
        cat /sys/class/net/$nic_name/address | head -n 1 | sed 's/://g'
        return 0
    fi

    for nic_path in /sys/class/net/*; do
        nic_name=$(basename "$nic_path")
        is_virtual=$(deref_path_symlink "$nic_path" | grep virtual)

        # skip possibly virtual or inactive devices  &&  
        if [ ! -z "$is_virtual" ] && [ "$(cat $nic_path/operstate)" = "up" ]; then 
            cat $nic_path/address | head -n 1 | sed 's/://g'
            break
        fi
    done
}

temperature_sensor_names() {
    if ! ls /sys/class/thermal/thermal_zone* > /dev/null 2>&1; then
        return
    fi

    for tz in /sys/class/thermal/thermal_zone*; do
        echo $(cat $tz/type | sed 's/-/_/')
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
        return
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

    swap_total_kB=$(echo "$mem" | grep SwapTotal | awk '{printf $2}')

    # check if no swap
    if [ $swap_total_kB -ne 0 ]; then
        swap_free_kB=$(echo "$mem" | grep SwapFree | awk '{printf $2}')
        swap_used_pc=$(echo | awk '{printf 100 * ('$swap_total_kB' - '$swap_free_kB') / '$swap_total_kB'}') 

        print_key_vals \
            swap_free_kB $swap_free_kB \
            swap_used_pc $swap_used_pc
        echo -n ","
    fi

    print_key_vals \
        mem_free_kB $mem_free_kB \
        mem_used_pc $mem_used_pc
}

host_name() {
    print_key_vals host_name \"$(cat /proc/sys/kernel/hostname)\"
}

##### Network functions #####

HTTP_HEADER_CTYPE="Content-Type: application/json"

HTTP_PATH_SENSOR="/api/states/sensor"
HTTP_PATH_MQTT="/api/services/mqtt/publish"

post_json_message_curl() {
    path="$1"
    json="$2"

    url="http://${HASS_SERVER}:${HASS_PORT}${path}"

    http_code=$(curl -m $TIMEOUT_SERVER --output /dev/null -s -X POST -w "%{http_code}\\n" -H "$HTTP_HEADER_AUTH" -H "$HTTP_HEADER_CTYPE" -d "$json" "$url")

    if [ "$http_code" != "200" ]; then
        error "received error:"
        printf '%b\n' "$http_code"
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

    result=$(printf '%b' "$data" | eval "$NETCAT_CMD $HASS_SERVER $HASS_PORT" 2>&1)
    sleep $TIMEOUT_SERVER

    http_code=$(echo "$result" | awk '/^HTTP/{print $2; exit}')

    if [ ! $http_code ]; then
        warning "message receipt not confirmed"
        return
    fi

    if [ "$http_code" != "200" ]; then
        error "received error:"
        printf '%b' "$result"
    else
        debug "message receipt confirmed"
    fi
}

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
    msg=$(print_json topic \"$topic\" payload "\"$json_str\"")

    post_json_message "$HTTP_PATH_MQTT" "$msg"
}

publish_state_loop() {
    info "Publishing state to topic $STATE_TOPIC every $MQTT_PUBLISH_PERIOD s"

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

        data="$(host_name),$(memory_usage),$(avg_load),$(uptime_duration),$(disk_usage),$(wifi_signal)"

        # add temperature sensors if available
        temp=$(temperature)

        if [ $temp ]; then
            data="${data},${temp}"
        fi

        json="{${data}}"

        debug "Publishing state message"
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
    msg=$msg,$(print_key_vals unit_of_measurement \"$unit_of_measurement\")
    msg=$msg,$(print_key_vals expire_after \"$((5 * $MQTT_PUBLISH_PERIOD))\")
    msg=$msg,$(print_key_vals value_template "\"{{ value_json.${param} }}\"")
    msg=$msg,$(print_key_vals unique_id \"$DEVICE_NAME-$param\")
    msg=$msg,$(print_key_vals device "$device")

    if [ $device_class ]; then
        msg="$msg,$(print_key_vals device_class \"$device_class\")"
    fi

    msg={$msg}

    debug "Sending discovery message for state $param"
    post_mqtt "$config_topic" "$msg"
}

publish_discovery_all() {
    info "Sending discovery messages"

    publish_discovery_sensor uptime_sec "Uptime" "s" "duration"

    publish_discovery_sensor avg_load_1min_pc "CPU load (1 min avg)" "%"
    publish_discovery_sensor avg_load_5min_pc "CPU load (5 min avg)" "%"
    publish_discovery_sensor avg_load_10min_pc "CPU load (10 min avg)" "%"

    publish_discovery_sensor mem_free_kB "Memory free" "kB"
    publish_discovery_sensor mem_used_pc "Memory used" "%"

    publish_discovery_sensor swap_free_kB "Swap free" "kB"
    publish_discovery_sensor swap_used_pc "Swap used" "%"

    publish_discovery_sensor wifi_link_pc "WiFi link" "%"
    publish_discovery_sensor wifi_level_dbm "WiFi level" "dBm" "signal_strength"

    publish_discovery_sensor disk_free_kb "Disk free" "kB"
    publish_discovery_sensor disk_used_pc "Disk used" "%"

    for sensor_name in $(temperature_sensor_names); do        
        var_name="temperature_${sensor_name}_C"
        sensor_name=$(echo $sensor_name | sed 's/_temp$//' | sed 's/_/ /')

        publish_discovery_sensor $var_name "Temperature $sensor_name" "°C" "temperature"
    done
}

setup() {
    config_file_name="$(basename $0 .sh).config"
    config_path_full="${PATH_CONFIG}/${config_file_name}"

    if [ -f "$config_path_full" ]; then
        info "Loading config from $config_path_full"
        . "$config_path_full"
    fi

    # need to set this here in case token gets loaded from file
    HTTP_HEADER_AUTH="Authorization: Bearer $HASS_TOKEN"

    if cmd_exists curl; then
        HAS_CURL=1
        debug  "Using curl"
        return 0
    elif cmd_exists netcat; then
        HAS_NETCAT=1
        NETCAT_CMD="netcat"
        debug "Using netcat"
    elif cmd_exists nc; then
        HAS_NETCAT=1
        NETCAT_CMD="nc"
        debug "Using nc"
    else
        error "Missing curl and netcat/nc, please install one"
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

    DEVICE_NAME="$(macid $NETWORK_IFACE)-$(cat /proc/sys/kernel/hostname)"
    STATE_TOPIC="$MQTT_PUB_PATH/$DEVICE_NAME/state"

    setup
    publish_discovery_all

    if [ $HAS_NETCAT_BASIC -eq 1 ]; then
        info "Discovery messages may not have been delivered, resending"
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

