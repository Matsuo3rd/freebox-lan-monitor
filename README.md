# freebox-lan-monitor

Monitors devices present in Freebox (French Internet Provider box) Local Area Network (LAN).
Sends notifications to a MQTT server when devices are entering or leaving network in order to pass on events to another process (such as home automation sofware).

## Description

This Shell script monitors devices on a Freebox LAN using Freebox API. It leverages "push notifications" from the Freebox Server (websocket): instead of regularly polling the network, the script subscribes to router's events. Hence, this approach can be less resource greedy and is quicker to react to network changes.

*However, do not expect near real-time feedback on devices' reachability*.

My use case is to trigger some home automation routines based on my smartphone and smartwatch presence on the network (ie. tracking WiFi connectivity). Notifications are pushed to a MQTT Server on which my home automation software is subscribed to.

## Prerequisites

* Freebox Server (tested on Freebox Delta)
* Always on computer able to run bash script (tested on macOS & Raspberry PI)
* `curl` command
* `jq` command
* `websocat` command
* optional: `mosquitto_pub` command

## Dependecies

Dependencies commands must either be available in PATH or directly put in the same directory as `freebox-lan-monitor.sh` script.

1. Check `curl` is avaible in PATH. If not download it.
2. Check `jq` is avaible in PATH. If not download it from [jq](https://stedolan.github.io/jq/).
3. Check `websocat` is avaible in PATH. If not install it from [websocat](https://github.com/vi/websocat/releases).
4. Optional: install `mosquitto_pub` using `sudo apt-get install mosquitto`

*NB*: I observed that jq 1.5 is way more faster than 1.6 under macOS. You shall install jq 1.5 if running under macOS.

## Installation

1. Create a dedicated directory (eg. `freebox-lan-monitor`)
2. Download `freebox-lan-monitor.sh` to dedicated directory
2. Make script executable using `chmod +x ./freebox-lan-monitor.sh`
3. Execute script `./freebox-lan-monitor.sh`
4. First time execution will require you to grant Freebox access to the script. Go to your Freebox front panel to approve access
5. Check log entry `LAN devices monitoring registration successful` confirming script is executing properly
6. Stop script (hitting ctrl-c)
7. Optional: if you wish to use MQTT, edit config file `config/mqtt_config.json` (see below)
8. Execute script in background `./freebox-lan-monitor.sh &`

## Making it a service

On RPI:

1. Edit `config/freebox-lan-monitor.service` and adapt `ExecStart` , `WorkingDirectory` and `User` settings accordingly
2. Copy `config/freebox-lan-monitor.service` file to `/etc/systemd/system/`
3. Execute `sudo systemctl enable freebox-lan-monitor.service`
4. Execute `sudo systemctl freebox-lan-monitor.service`

## Configuration

If you wish to push MQTT messages, `config/mqtt_config.json` file shall contains the following keys/values:

| Key | Default | Description |
| --- | --- | --- |
| `mosquitto_pub_params` | N/A | Parameters passed to mosquitt_pub command along with pushed message. eg. "-h rpi4.local" (to pass MQTT broker hostname)|
| `mqtt_topic` | N/A | MQTT topic name to which messages will be added. eg. "freebox-lan-monitor" |

Configuration sample:

```json
{
   "mosquitto_pub_params": "-h rpi4.local",
   "mqtt_topic" : "freebox-lan-monitor"
}
```
