#!/bin/sh
# sysmon.sh v0.1

TOKEN="TOKEN HERE"
SERVER="192.168.1.1"
PORT="8123"

DEBUG_LEVEL=1
PUBLISH_PERIOD=15
NC_DELAY=1

SENSOR_PATH="/api/states/sensor"
MQTT_PATH="/api/services/mqtt/publish"

PUBLISH_DELAY=0
NC_CMD="nc"
CPU_COUNT=$(grep -c ^processor /proc/cpuinfo)

COLOR_RESET="\033[0m"
COLOR_RED="\033[31;1m"
COLOR_GREEN="\033[32;1m"
COLOR_BLUE="\033[33;1m"
COLOR_GRAY="\033[37;1m"

##### Logging functions #####

# debug levels:
# 0 = DEBUG, 1 = INFO, 2 = WARN, 3=ERROR

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

macid()
{
    echo $(cat /sys/class/net/*/address | head -n 1 | sed 's/://g')
}

temperature_sensors() {
    if ! ls /sys/class/thermal/thermal_zone* > /dev/null 2>&1; then
        return
    fi

    for tz in /sys/class/thermal/thermal_zone*; do
        echo $(cat $tz/type | sed 's/-/_/')
    done
}

##### Sensor functions #####

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

post_json_message() {
    path="$1"
    json="$2"

    data="POST $path HTTP/1.1\r
Authorization: Bearer $TOKEN\r
Content-Type: application/json\r
Content-Length: ${#json}\r
\r
"
    data="${data}${json}"

    result=$(printf '%b' "$data" | eval "$NC_CMD $SERVER $PORT" 2>&1)
    sleep $PUBLISH_DELAY

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

post_sensor_state() {
    path="$SENSOR_PATH.$1"
    json="$2"

    post_json_message "$path" "$json"
}

post_mqtt() {
    topic="$1"
    json_str=$(echo "$2" | sed 's/"/\\"/g')
    msg=$(print_json topic \"$topic\" payload "\"$json_str\"")

    post_json_message "$MQTT_PATH" "$msg"
}

publish_state_loop() {
    info "Publishing state to topic: $STATE_TOPIC"

    while true
    do
        data="$(host_name),$(memory_usage),$(avg_load),$(uptime_duration),$(disk_usage),$(wifi_signal)"

        # add temperature sensors if available
        temp=$(temperature)

        if [ $temp ]; then
            data="${data},${temp}"
        fi

        json="{${data}}"

        debug "Sending message"
        post_mqtt "$STATE_TOPIC" "$json"
        debug "=> done"

        sleep $(($PUBLISH_PERIOD - $NC_DELAY - $PUBLISH_DELAY))
    done
}

publish_discovery_sensor() {
    param="$1"
    name="$2"
    unit_of_measurement="$3"
    device_class="$4"

    CONFIG_TOPIC="homeassistant/sensor/$DEVICE_NAME/$param/config"

    device_name="System statistics $DEVICE_NAME"
    version="$(uname -a)"
    device=$(print_json identifiers '["'"$DEVICE_NAME"'"]' name "\"$device_name\"" sw_version "\"$version\"")

    msg=$(print_key_vals name "\"$name\"")
    msg=$msg,$(print_key_vals state_topic \"$STATE_TOPIC\")
    msg=$msg,$(print_key_vals unit_of_measurement \"$unit_of_measurement\")
    msg=$msg,$(print_key_vals expire_after \"$((5 * $PUBLISH_PERIOD))\")
    msg=$msg,$(print_key_vals value_template "\"{{ value_json.${param} }}\"")
    msg=$msg,$(print_key_vals unique_id \"$DEVICE_NAME-$param\")
    msg=$msg,$(print_key_vals device "$device")

    if [ $device_class ]; then
        msg="$msg,$(print_key_vals device_class \"$device_class\")"
    fi

    msg={$msg}

    debug "Sending discovery message for state $param"
    post_mqtt "$CONFIG_TOPIC" "$msg"
    debug "=> done"
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

    for sensor_name in $(temperature_sensors); do        
        var_name="temperature_${sensor_name}_C"
        sensor_name=$(echo $sensor_name | sed 's/_temp$//' | sed 's/_/ /')

        publish_discovery_sensor $var_name "Temperature $sensor_name" "°C" "temperature"
    done
}

if ! cmd_exists nc; then
    debug "Using 'netcat' binary"
    NC_CMD="netcat"
fi

if $NC_CMD 2>&1 | grep "\-w" > /dev/null; then
    debug "Using netcat delay of $NC_DELAY"
    NC_CMD="$NC_CMD -w $NC_DELAY"
else
    PUBLISH_DELAY=$NC_DELAY
    NC_DELAY=0
fi

DEVICE_NAME="$(macid)-$(cat /proc/sys/kernel/hostname)"
STATE_TOPIC="/home/servers/$DEVICE_NAME/state"

publish_discovery_all
publish_state_loop


