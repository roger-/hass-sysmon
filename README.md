# hass-sysmon
Minimal Linux system monitor with Home Assistant MQTT Discovery support for devices running OpenWrt, Raspberry Pi OS, Debian, Ubuntu, etc.

# Why
I needed a simple way to get system statistics from some Linux machines into Home Assistant (including several running OpenWrt with only KBs of free diskspace) but most existing solutions were either too complicated, bloated, slow or required too many dependancies.

hass-sysmon is a ~10 KB POSIX-compliant shell script (Dash, Bash, etc.) that exposes the following sensors to Home Assistant via MQTT Discovery:

* CPU load
* Memory/swap usage
* Disk usage (only `/` for now)
* Uptime
* Temperature
* WiFi RSSI/link quality

`netcat` is used to send HTTP POST messages to the Home Assistant MQTT service, which publishes the messages over MQTT back to Home Assistant.

# Requirements

The only major dependancy is `netcat`/`nc`, which is installed by default on OpenWrt and some Debian systems. 

Home Assistant should be on the same LAN and should have MQTT enabled.

# How
Copy `sysmon.sh` to your machine somewhere and edit the following variables:

* `TOKEN`: should be a Home Assistant long-lived token (generate at `[User profile]` -> `Long-Lived Access Tokens` -> `Create Token`)
* `SERVER`: IP address of your Home Assistant machine
* `PORT`: Home Assistant HTTP port (8123 by default)
* `DEBUG_LEVEL`: change to 0 for more debug messages
* `PUBLISH_PERIOD`: how often to publish (15s by default)

Now run `sysmon.sh` and you should soon see a new device called "System statistics..." with entities like this:

<img width="247" alt="Screenshot 2022-11-15 090209" src="https://user-images.githubusercontent.com/1389709/201938699-7f4ff2cc-e9e7-4ef5-93c9-512f36b111d0.png">

On OpenWrt you can have this automatically run at boot by modifying `/etc/rc.local`, and on modern Debian-based systems you can create a systemd service.

# Additional notes

* MAC addresses aren't correctly detected (especially on machines with multiple network interfaces). This isn't too consequential but you might running into issues if you have multiple Raspberry Pi's with identical host names, for example.
* The busybox version of `netcat` included in OpenWrt is very barebones and doesn't support timeouts. Consequently it can't reliably confirm POST messages were successfully delivered and some may be dropped. You may need to run the script several times to make sure all the MQTT Discovery messages are sent correctly (increasing `NC_DELAY` might help).
* If you see any errors then try setting `DEBUG_LEVEL=0` to get more details.
* You can also examine the HTTP POST messages by running another instance of `netcat` as a listener and change `PORT` accordingly, e.g. run `nc -l 1111` and run `sysmon.sh` with `PORT=1111`.
