# voice-fleet:satellite service

The ESPHome native API of the Home Assistant Voice satellites.

## What a consumer gets

- **Network access**: `pinhole.json` opens TCP 6053 from the consumer to the
  satellites (auto-pinhole, #173). Home Assistant uses it for wake word
  events, microphone audio and control.

Nothing is installed on the satellites or on the consumer.

## How to use it

```json
"dependsOn": ["network:rules", "voice-fleet:satellite"]
```

## Fields

`voice-fleet:satellite` declares no fields.
