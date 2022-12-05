# hass-sysmon
Minimal Linux system monitor with Home Assistant MQTT Discovery support for devices running OpenWrt, Raspberry Pi OS, Debian, Ubuntu, etc.

# Why
I needed a simple way to get system statistics from some Linux machines into Home Assistant (including several running OpenWrt with only KBs of free diskspace) but most existing solutions were either too complicated, bloated, slow or required too many dependancies.

hass-sysmon is a ~10 KB (almost) POSIX-compliant shell script (Dash, Bash, etc.) that exposes the following sensors to Home Assistant via MQTT Discovery:

* CPU load
* Memory/swap usage
* Disk usage (only `/` for now)
* Uptime
* Temperature
* WiFi RSSI/link quality

# How
HTTP POST messages are sent to the Home Assistant MQTT service, which then publishes the messages over MQTT back to Home Assistant. If available, the `curl` command will be used otherwise it will fallback to `netcat`/`nc`, which is installed by default on OpenWrt and some Debian systems. 

Home Assistant should be on the same LAN and should have MQTT enabled.

# Usage
In either `sysmon.config` or directly in `sysmon.sh`, update at least the following configuration variables:

* `HASS_TOKEN`: should be a Home Assistant long-lived token (generate at `[User profile]` -> `Long-Lived Access Tokens` -> `Create Token`)
* `HASS_SERVER`: address of your Home Assistant machine
* `HASS_PORT`: Home Assistant HTTP port (8123 by default)

Now run `sysmon.sh` or `sysmon.sh <config directory>` (if using a config file in a different directory) and you should soon see a new device in Home Assistant called "System statistics..." with entities like this:

<img width="247" alt="Screenshot 2022-11-15 090209" src="https://user-images.githubusercontent.com/1389709/201938699-7f4ff2cc-e9e7-4ef5-93c9-512f36b111d0.png">

On OpenWrt you can have this automatically run at boot by modifying `/etc/rc.local`, and on modern Debian-based systems you can create a systemd service.

# Additional notes

* A MAC address is used as a unique machine ID. By default the first active NIC is used but this can be overwritten by setting `NETWORK_IFACE` in the configuration.
* The busybox version of `netcat` included in OpenWrt is very barebones and doesn't support timeouts. Consequently it can't reliably confirm POST messages were successfully delivered and some may be dropped. You may need to run the script several times to make sure all the MQTT Discovery messages are sent correctly (increasing `TIMEOUT_SERVER` might help).
* If you see any errors then try setting `DEBUG_LEVEL=0` to get more details.
* You can also examine the HTTP POST messages by running another instance of `netcat` as a listener and change `PORT` accordingly, e.g. run `nc -l 1111` and run `sysmon.sh` with `HASS_PORT=1111`.
