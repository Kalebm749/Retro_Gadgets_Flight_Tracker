# Retro Gadgets Flight Tracker

A real-time ADS-B aircraft tracker built for [Retro Gadgets](https://store.steampowered.com/app/1730260/Retro_Gadgets/) — the hardware tinkering sandbox game. This gadget pulls live flight data from public ADS-B APIs and displays aircraft on a radar scope with geographic airport maps, traffic lists, and detailed aircraft information panels.

![Retro Gadgets](https://img.shields.io/badge/Platform-Retro%20Gadgets-green)
![Language](https://img.shields.io/badge/Language-Lua-blue)
![License](https://img.shields.io/badge/License-MIT-yellow)

---

## Features

### Live ADS-B Data
- Pulls real-time aircraft positions from **two API providers** with automatic failover:
  - [ADSB.FI](https://opendata.adsb.fi) (OpenData ADS-B)
  - [ADSB.LOL](https://api.adsb.lol)
- Adaptive polling interval that speeds up after successful fetches and backs off on errors
- Automatic rate-limit handling with per-provider cooldowns
- Request timeout detection with automatic retry logic

### Radar Display (VideoChip0)
- Circular radar scope with range rings (33%, 66%, 100%)
- Geographic airport maps generated from **OpenStreetMap** data showing:
  - Runways (thick lines, visible at all zoom levels)
  - Taxiways (visible at ≤3 NM)
  - Aprons/ramps (visible at ≤5 NM)
  - Buildings (visible at ≤3 NM)
  - Airport boundaries
  - Roads and water features
- Aircraft symbols with heading indicators
- Color-coded by status: green (arriving), blue (departing), gray (ground), white (overflying)
- Emergency squawk codes (7500/7600/7700) shown in red
- Selected aircraft highlighted with amber ring and callsign label
- Aircraft trails showing recent path history
- **Stick0 pan navigation** — pan around the full 10 NM data area when zoomed in

### Traffic List (VideoChip1)
- Scrollable list of all aircraft within the selected range
- Shows: callsign, status (A/D/G/O), distance, altitude (flight level), ground speed
- Currently selected aircraft highlighted in amber
- Displays scan status and error messages when no traffic

### Aircraft Details Panel (VideoChip2)
- Detailed info for the selected aircraft:
  - Callsign, registration, aircraft type
  - Altitude, ground speed, heading
  - Distance and bearing from airport
  - Vertical rate, squawk code
  - Aircraft description
  - Emergency status

### Control Panel (VideoChip3)
- On-screen buttons for range selection and feature toggles
- Visual feedback showing active range and toggle states

### Status LCD
- Displays current poll interval and data age
- Shows count of airborne vs ground aircraft

---

## Supported Airports

| ICAO | Name | Location |
|------|------|----------|
| KAPA | Centennial Airport | Englewood, CO |
| KDEN | Denver International | Denver, CO |
| KBJC | Rocky Mountain Metro | Broomfield, CO |
| KFTG | Front Range (CO Air Space Port) | Watkins, CO |
| KCOS | Colorado Springs | Colorado Springs, CO |
| KASE | Aspen-Pitkin County | Aspen, CO |

All airports include detailed geographic map data from OpenStreetMap in `airport_maps.lua`.

---

## Hardware Layout

### Required Gadget Components

| Component | Purpose |
|-----------|---------|
| **CPU0** | Main processor (provides Time, DeltaTime) |
| **Wifi0** | Internet access for API calls |
| **VideoChip0** | Radar display |
| **VideoChip1** | Traffic list display |
| **VideoChip2** | Aircraft details display |
| **VideoChip3** | Control button labels |
| **Knob0** | Airport selection |
| **Knob1** | Aircraft selection (scroll through traffic) |
| **Stick0** | Pan navigation (when range < 10 NM) |
| **LedButton0** | Manual refresh (LED shows network status) |
| **ScreenButton0–3** | Range selection: 1, 3, 5, 10 NM |
| **ScreenButton4** | Toggle trails ON/OFF |
| **ScreenButton5** | Toggle emergency alerts ON/OFF |
| **Lcd0** | Status readout (poll interval, aircraft counts) |
| **FlashMemory0** | Persistent settings storage |

### Controls

| Input | Action |
|-------|--------|
| **Knob0** (rotate) | Select airport |
| **Knob1** (rotate) | Scroll through aircraft list |
| **Stick0** (tilt) | Pan radar view (only when range < 10 NM) |
| **LedButton0** (press) | Force manual data refresh |
| **ScreenButton 1–4** | Set radar range: 1, 3, 5, or 10 NM |
| **ScreenButton 5** | Toggle aircraft trail lines |
| **ScreenButton 6** | Toggle emergency alert highlighting |

### Stick0 Pan Navigation

When viewing at 1, 3, or 5 NM range, the radar only shows a portion of the 10 NM data cache. Use **Stick0** to pan the view around the full data area:

| Range | Max Pan Distance | Description |
|-------|-----------------|-------------|
| 1 NM | ±9 NM | Full freedom to explore the data area |
| 3 NM | ±7 NM | Large pan range |
| 5 NM | ±5 NM | Moderate pan range |
| 10 NM | None (disabled) | Full area already visible |

Pan automatically resets to center when switching to the 10 NM range.

---

## LED Indicators

| LED | Color | Meaning |
|-----|-------|---------|
| LedButton0 | Green (solid) | Online, data received successfully |
| LedButton0 | Green (flashing) | Request in progress |
| LedButton0 | Red | API error or network issue |

---

## Network & API Behavior

- **Data radius**: Always fetches aircraft within 10 NM of the selected airport regardless of display range
- **Adaptive polling**: Starts at 12s, speeds up to 5s after consecutive successes, backs off up to 180s on failures
- **Dual provider failover**: If one API fails or rate-limits, automatically switches to the other
- **Rate limit handling**: HTTP 429 responses trigger per-provider cooldowns with exponential backoff
- **Request timeout**: 20 seconds, after which the request is aborted and retried with the alternate provider

---

## File Structure

```
├── airport_tracker.lua    # Main gadget code (logic, rendering, networking)
├── airport_maps.lua       # Geographic map data for all airports (from OSM)
└── README.md              # This file
```

### airport_tracker.lua

The main script containing:
- API request/response handling with dual-provider failover
- Aircraft data processing and filtering
- Radar rendering with geographic maps
- Traffic list and detail panel drawing
- Input handling (knobs, buttons, stick)
- Settings persistence via FlashMemory
- Comprehensive debug logging system

### airport_maps.lua

OpenStreetMap-derived geographic data for each airport, organized by layer:
- `runway` — Runway paths
- `taxiway` — Taxiway centerlines
- `apron` — Apron/ramp areas
- `building` — Terminal and hangar outlines
- `boundary` — Airport boundary perimeter
- `road` — Nearby roads
- `water` — Water features

Coordinates are stored as east/north offsets in nautical miles from the airport reference point.

---

## Configuration

Key constants at the top of `airport_tracker.lua`:

```lua
local START_POLL_INTERVAL = 12      -- Initial seconds between API polls
local MIN_POLL_INTERVAL = 5         -- Fastest polling rate
local MAX_POLL_INTERVAL = 180       -- Slowest polling rate (during errors)
local DATA_RADIUS = 10              -- NM radius for API data fetch
local REQUEST_TIMEOUT = 20          -- Seconds before aborting a request
local STARTUP_DELAY = 1.5           -- Seconds before first request
local DRAW_INTERVAL = 0.1           -- Seconds between screen redraws
local MAX_TRAIL_POINTS = 10         -- Max trail history per aircraft
local PAN_SPEED = 0.005             -- NM per tick stick pan speed
local PAN_DEADZONE = 0.1            -- Stick deadzone threshold
```

### Debug Mode

Set `DEBUG = true` at the top of the file to enable detailed logging:
- Network state transitions
- API request/response details
- Aircraft processing statistics
- Periodic status summaries (every 10 seconds)

---

## Aircraft Status Codes

| Code | Meaning | Criteria |
|------|---------|----------|
| ARR | Arriving | Within 3 NM, descending (vertical rate < -200 ft/min) |
| DEP | Departing | Within 3 NM, climbing (vertical rate > +200 ft/min) |
| GND | Ground | Altitude reported as "ground" |
| OVR | Overflying | All other airborne aircraft |

---

## Color Scheme

The display uses a retro green-phosphor CRT aesthetic:

| Element | Color |
|---------|-------|
| Background | Near-black (5, 10, 8) |
| Radar rings | Dark green |
| Range ring (outer) | Dim green |
| Airport label | Green |
| Arriving aircraft | Green |
| Departing aircraft | Blue |
| Ground aircraft | Gray |
| Overflying aircraft | White |
| Selected aircraft | Amber |
| Emergency | Red |
| Runways (map) | Light gray |
| Taxiways (map) | Dark olive |
| Buildings (map) | Teal |

---

## Data Sources

- **Aircraft positions**: [ADS-B Exchange](https://www.adsbexchange.com/) community feeders via ADSB.FI and ADSB.LOL public APIs
- **Airport maps**: [OpenStreetMap](https://www.openstreetmap.org/) © OpenStreetMap contributors

---

## Installation

1. Open **Retro Gadgets** in Steam
2. Create a new gadget with the required components listed above
3. Copy `airport_tracker.lua` as the main CPU script
4. Place `airport_maps.lua` in the same gadget directory so it can be `require()`'d
5. Connect all components to the CPU and ensure WiFi permissions are granted
6. Power on and wait for the initial data fetch (~1.5 seconds)

---

## Tips

- **First boot**: The gadget needs WiFi access permission. Grant it when prompted.
- **Rate limiting**: If you see "RATE LIMIT" errors, the gadget will automatically back off and switch providers. Just wait.
- **Pan reset**: Switch to 10 NM range to instantly reset the pan position to center.
- **Trails**: Toggle trails off if the display feels cluttered at busy airports like KDEN.
- **Airport selection**: The knob maps evenly across all airports — small rotations may jump between them.
- **Settings persist**: Your selected airport, range, trail, and alert preferences are saved to FlashMemory and restored on next power-on.

---

## Contributing

Feel free to fork and extend! Some ideas:
- Add more airports (generate map data from OSM for any airport worldwide)
- Add altitude filtering
- Add a flight history log
- Implement weather overlay (METAR data)
- Add audio alerts for emergency squawks

---

## License

This project is open source. Aircraft data is provided by community ADS-B feeders via public APIs. Map data © OpenStreetMap contributors, licensed under ODbL.
