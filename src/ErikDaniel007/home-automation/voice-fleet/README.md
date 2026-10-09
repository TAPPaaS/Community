# voice-fleet — Home Assistant Voice satellites

Policy-only TAPPaaS module for Home Assistant Voice devices (ESPHome
satellites). No VM: it declares the network policy the devices need,
nothing is deployed.

## What it does

A voice satellite talks to Home Assistant in two directions:

| Direction | Port | Used for |
|---|---|---|
| Home Assistant → satellite | TCP 6053 | ESPHome native API: wake word events, microphone audio, control |
| Satellite → Home Assistant | TCP 8123 | The satellite fetches the spoken answer (TTS audio) by HTTP |

The second one is the one that is easy to miss. Without it the satellite
hears you, Home Assistant answers, and the room stays silent: the device
gets a URL on Home Assistant and cannot reach it.

## Services offered (`provides`)

| Service     | Ports    | Used for           |
|-------------|----------|--------------------|
| `satellite` | TCP 6053 | ESPHome native API |

## Network placement

- **Zone**: `iotCloud`. The devices are updated over the internet.
- **Alias**: the `iotCloud` subnet (`aliasType: network`). The fleet has no
  single hostname, so rules match the zone subnet rather than an FQDN.
- **Consequence**: the `egress` rule opens TCP 8123 on the Home Assistant
  host for every device in `iotCloud`, not only for the satellites. That
  port asks for a login for everything except the audio links, which are
  unguessable and short-lived. If that is too wide for your site, give each
  satellite its own module with `aliasType: host`.

## The Home Assistant instance

The `egress` rule names its destination as `hass`, the module name of Home
Assistant. If your instance has another name, set it when you add the
module, so the rule points at your instance.

## Symptom this module fixes

The satellite reacts to the wake word and plays its wake sound. In Home
Assistant the pipeline run ends without an error, with text in the
`tts-start` event. The satellite's media player never reaches `playing`
during the answer, and its state `responding` ends after about two seconds
whatever the length of the answer.
