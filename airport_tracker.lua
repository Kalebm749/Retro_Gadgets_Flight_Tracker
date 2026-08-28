local json = require("json")
local airportMaps = require("airport_maps.lua")

--------------------------------------------------
-- Debug configuration
--------------------------------------------------

local DEBUG = true
local DEBUG_RESPONSE_PREVIEW = true
local DEBUG_AIRCRAFT = true
local DEBUG_STATUS_INTERVAL = 10
local RESPONSE_PREVIEW_LENGTH = 300

function debugLog(message)
    if DEBUG then
        log(
            "[DEBUG " ..
            string.format(
                "%.1f",
                gdt.CPU0.Time
            ) ..
            "] " ..
            tostring(message)
        )
    end
end


function debugWarning(message)
    if DEBUG then
        logWarning(
            "[WARN " ..
            string.format(
                "%.1f",
                gdt.CPU0.Time
            ) ..
            "] " ..
            tostring(message)
        )
    end
end


function debugError(message)
    logError(
        "[ERROR " ..
        string.format(
            "%.1f",
            gdt.CPU0.Time
        ) ..
        "] " ..
        tostring(message)
    )
end

--------------------------------------------------
-- Configuration
--------------------------------------------------

local API_PROVIDERS = {
    {
        name = "ADSB.FI",
        style = "fi",
        base = "https://opendata.adsb.fi/api/v3/lat/"
    },
    {
        name = "ADSB.LOL",
        style = "lol",
        base = "https://api.adsb.lol/v2/point/"
    }
}

local START_POLL_INTERVAL = 12
local MIN_POLL_INTERVAL = 5
local MAX_POLL_INTERVAL = 180
local SPEED_UP_AFTER_SUCCESSES = 2
local POLL_SPEEDUP_STEP = 2
local DATA_RADIUS = 10
local REQUEST_TIMEOUT = 20
local INITIAL_REQUEST_TIMEOUT = 20
local STARTUP_DELAY = 1.5
local RETRY_DELAY = 3
local MAX_RETRY_DELAY = 60
local DRAW_INTERVAL = 0.1
local MAX_TRAIL_POINTS = 10

local BLACK = Color(5, 10, 8)
local DARK_GREEN = Color(15, 45, 25)
local GREEN = Color(40, 255, 100)
local DIM_GREEN = Color(20, 120, 60)
local WHITE = Color(220, 255, 225)
local AMBER = Color(255, 170, 20)
local RED = Color(255, 35, 25)
local BLUE = Color(40, 150, 255)
local GRAY = Color(100, 120, 110)
local MAP_RUNWAY = Color(115, 125, 120)
local MAP_TAXIWAY = Color(75, 90, 82)
local MAP_APRON = Color(48, 62, 55)
local MAP_BUILDING = Color(38, 70, 78)
local MAP_BOUNDARY = Color(25, 95, 55)
local MAP_ROAD = Color(105, 75, 30)
local MAP_WATER = Color(22, 58, 90)

local airports = {
    {
        icao = "KAPA",
        name = "CENTENNIAL",
        lat = 39.5701,
        lon = -104.8493,
        runways = {170, 100}
    },
    {
        icao = "KDEN",
        name = "DENVER INTL",
        lat = 39.8561,
        lon = -104.6737,
        runways = {160, 170, 80, 70}
    },
    {
        icao = "KBJC",
        name = "ROCKY MTN",
        lat = 39.9088,
        lon = -105.1172,
        runways = {120, 30}
    },
    {
        icao = "KFTG",
        name = "CO AIR SPACE",
        lat = 39.7842,
        lon = -104.5376,
        runways = {80, 170}
    },
    {
        icao = "KCOS",
        name = "CO SPRINGS",
        lat = 38.8058,
        lon = -104.7008,
        runways = {170, 130}
    },
    {
        icao = "KASE",
        name = "ASPEN",
        lat = 39.2232,
        lon = -106.8688,
        runways = {150}
    }
}

local ranges = {1, 3, 5, 10}

local font =
    gdt.ROM.System.SpriteSheets[
        "StandardFont"
    ]

--------------------------------------------------
-- State
--------------------------------------------------

local airportIndex = 1
local rangeIndex = 3
local aircraftIndex = 1

local aircraft = {}
local allAircraft = {}
local trails = {}

local selectedHex = nil
local followMode = false
local trailsEnabled = true
local alertsEnabled = true

local requestHandle = nil
local requestStartedAt = 0
local requestCount = 0
local responseCount = 0
local timeoutCount = 0
local retryCount = 0
local initialLoadComplete = false
local adaptivePollInterval = START_POLL_INTERVAL
local successfulPolls = 0
local rateLimitedUntil = 0
local lastSuccessfulRefresh = nil
local providerIndex = 1
local requestProviderIndex = nil
local providerCooldowns = {0, 0}

local nextPoll = STARTUP_DELAY
local drawTimer = 0
local nextDebugStatus = 0

local networkState = "idle"
local lastError = ""

local lastAircraftKnob = nil
local lastAirportKnob = nil

local panOffsetX = 0
local panOffsetY = 0
local PAN_SPEED = 0.005
local PAN_DEADZONE = 0.1

--------------------------------------------------
-- General helpers
--------------------------------------------------

function clamp(value, minimum, maximum)
    return math.max(
        minimum,
        math.min(maximum, value)
    )
end


function trim(value)
    return string.match(
        tostring(value or ""),
        "^%s*(.-)%s*$"
    )
end


function safeNumber(value, fallback)
    local number = tonumber(value)

    if number == nil then
        return fallback or 0
    end

    return number
end


function knobIndex(knob, count)
    local normalized =
        (knob.Value + 100) / 200

    local index =
        math.floor(
            normalized * count
        ) + 1

    return clamp(index, 1, count)
end


function shortText(value, length)
    local text = trim(value)

    if text == "" then
        text = "-"
    end

    return string.sub(text, 1, length)
end


function formatAltitude(value)
    if value == "ground" then
        return "GND"
    end

    local altitude = tonumber(value)

    if not altitude then
        return "---"
    end

    if altitude >= 1000 then
        return tostring(
            math.floor(altitude / 100)
        )
    end

    return tostring(
        math.floor(altitude)
    )
end


function setNetworkState(
    newState,
    reason
)
    if networkState ~= newState then
        debugLog(
            "Network state: " ..
            tostring(networkState) ..
            " -> " ..
            tostring(newState) ..
            (
                reason and
                " (" .. tostring(reason) .. ")"
                or ""
            )
        )
    end

    networkState = newState
end

--------------------------------------------------
-- Geometry
--------------------------------------------------

function aircraftOffset(
    latitude,
    longitude,
    airport
)
    local north =
        (latitude - airport.lat) * 60

    local east =
        (longitude - airport.lon) *
        60 *
        math.cos(
            math.rad(airport.lat)
        )

    return east, north
end


function distanceFromAirport(
    latitude,
    longitude,
    airport
)
    local east, north =
        aircraftOffset(
            latitude,
            longitude,
            airport
        )

    return math.sqrt(
        east * east +
        north * north
    )
end


function bearingFromAirport(
    latitude,
    longitude,
    airport
)
    local east, north =
        aircraftOffset(
            latitude,
            longitude,
            airport
        )

    local angle =
        math.deg(
            math.atan2(east, north)
        )

    if angle < 0 then
        angle = angle + 360
    end

    return angle
end


function radarPosition(
    latitude,
    longitude,
    width,
    height
)
    local airport =
        airports[airportIndex]

    local east, north =
        aircraftOffset(
            latitude,
            longitude,
            airport
        )

    local radius = ranges[rangeIndex]

    local scale =
        math.min(width, height) /
        2 - 5

    return
        width / 2 +
        (east - panOffsetX) / radius * scale,
        height / 2 -
        (north - panOffsetY) / radius * scale
end


function radarOffsetPosition(
    east,
    north,
    width,
    height
)
    local radius = ranges[rangeIndex]

    local scale =
        math.min(width, height) /
        2 - 5

    return
        width / 2 +
        (east - panOffsetX) / radius * scale,
        height / 2 -
        (north - panOffsetY) / radius * scale
end

--------------------------------------------------
-- Aircraft processing
--------------------------------------------------

function aircraftStatus(item)
    if item.altitude == "ground" then
        return "GND"
    end

    if item.distance <= 3 then
        if item.verticalRate < -200 then
            return "ARR"
        elseif item.verticalRate > 200 then
            return "DEP"
        end
    end

    return "OVR"
end


function processAircraft(source)
    if source.lat == nil
        or source.lon == nil then

        if DEBUG_AIRCRAFT then
            debugWarning(
                "Skipped aircraft " ..
                tostring(source.hex) ..
                ": missing position"
            )
        end

        return nil
    end

    local airport =
        airports[airportIndex]

    local item = {
        hex = trim(source.hex),
        callsign = trim(source.flight),
        registration = trim(source.r),
        aircraftType = trim(source.t),
        description = trim(source.desc),

        lat = safeNumber(source.lat),
        lon = safeNumber(source.lon),

        altitude = source.alt_baro,
        geometricAltitude =
            source.alt_geom,

        speed = safeNumber(source.gs),

        heading = safeNumber(
            source.track,
            safeNumber(
                source.true_heading,
                safeNumber(
                    source.mag_heading,
                    0
                )
            )
        ),

        verticalRate = safeNumber(
            source.baro_rate,
            safeNumber(
                source.geom_rate,
                0
            )
        ),

        squawk = trim(source.squawk),
        emergency =
            trim(source.emergency),

        category = trim(source.category),
        seen = safeNumber(source.seen)
    }

    if item.callsign == "" then
        if item.registration ~= "" then
            item.callsign =
                item.registration
        else
            item.callsign =
                string.upper(item.hex)
        end
    end

    item.distance =
        distanceFromAirport(
            item.lat,
            item.lon,
            airport
        )

    item.bearing =
        bearingFromAirport(
            item.lat,
            item.lon,
            airport
        )

    item.status =
        aircraftStatus(item)

    return item
end


function sortAircraft()
    table.sort(
        aircraft,
        function(a, b)
            return a.distance <
                b.distance
        end
    )
end


function applyRangeFilter()
    local previousHex = selectedHex

    aircraft = {}

    for _, item in ipairs(allAircraft) do
        if item.distance <=
            ranges[rangeIndex] then

            table.insert(aircraft, item)
        end
    end

    sortAircraft()

    local retainedIndex = nil

    if previousHex then
        for index, item in ipairs(aircraft) do
            if item.hex == previousHex then
                retainedIndex = index
                break
            end
        end
    end

    if retainedIndex then
        aircraftIndex = retainedIndex
        selectedHex = previousHex
    elseif #aircraft > 0 then
        aircraftIndex = clamp(
            aircraftIndex,
            1,
            #aircraft
        )
        selectedHex =
            aircraft[aircraftIndex].hex
        followMode = false
    else
        aircraftIndex = 1
        selectedHex = nil
        followMode = false
    end

    debugLog(
        "Range filter: " ..
        tostring(#aircraft) ..
        " of " ..
        tostring(#allAircraft) ..
        " aircraft inside " ..
        tostring(ranges[rangeIndex]) ..
        " NM"
    )
end


function findAircraftByHex(hex)
    if not hex then
        return nil, nil
    end

    for index, item in ipairs(aircraft) do
        if item.hex == hex then
            return item, index
        end
    end

    return nil, nil
end


function selectedAircraft()
    if #aircraft == 0 then
        return nil
    end

    if followMode and selectedHex then
        local item, index =
            findAircraftByHex(
                selectedHex
            )

        if item then
            aircraftIndex = index
            return item
        end
    end

    aircraftIndex =
        clamp(
            aircraftIndex,
            1,
            #aircraft
        )

    local item =
        aircraft[aircraftIndex]

    selectedHex = item.hex

    return item
end

--------------------------------------------------
-- Trails
--------------------------------------------------

function updateTrails(sourceAircraft)
    if not trailsEnabled then
        trails = {}
        return
    end

    local pointsAdded = 0

    local items = sourceAircraft or aircraft

    for _, item in ipairs(items) do
        if item.hex ~= "" then
            local trail =
                trails[item.hex] or {}

            local previous =
                trail[#trail]

            if not previous
                or previous.lat ~= item.lat
                or previous.lon ~= item.lon then

                table.insert(trail, {
                    lat = item.lat,
                    lon = item.lon
                })

                pointsAdded =
                    pointsAdded + 1
            end

            while #trail >
                MAX_TRAIL_POINTS do

                table.remove(trail, 1)
            end

            trails[item.hex] = trail
        end
    end

    debugLog(
        "Trail update: " ..
        tostring(pointsAdded) ..
        " points added"
    )
end

--------------------------------------------------
-- Saved settings
--------------------------------------------------

function saveSettings()
    local success =
        gdt.FlashMemory0:Save({
            airportIndex = airportIndex,
            rangeIndex = rangeIndex,
            trailsEnabled = trailsEnabled,
            alertsEnabled = alertsEnabled
        })

    debugLog(
        "Settings save: " ..
        tostring(success) ..
        ", airport=" ..
        airports[airportIndex].icao ..
        ", range=" ..
        tostring(ranges[rangeIndex]) ..
        "NM, trails=" ..
        tostring(trailsEnabled) ..
        ", alerts=" ..
        tostring(alertsEnabled)
    )
end


function loadSettings()
    if gdt.FlashMemory0.Usage == 0 then
        debugLog(
            "FlashMemory is empty"
        )

        return
    end

    debugLog(
        "Loading settings from FlashMemory, usage=" ..
        tostring(
            gdt.FlashMemory0.Usage
        )
    )

    local success, data = pcall(
        function()
            return gdt.FlashMemory0:Load()
        end
    )

    if not success then
        debugError(
            "FlashMemory load failed: " ..
            tostring(data)
        )

        return
    end

    if type(data) ~= "table" then
        debugError(
            "FlashMemory returned " ..
            tostring(type(data))
        )

        return
    end

    airportIndex =
        clamp(
            safeNumber(
                data.airportIndex,
                airportIndex
            ),
            1,
            #airports
        )

    rangeIndex =
        clamp(
            safeNumber(
                data.rangeIndex,
                rangeIndex
            ),
            1,
            #ranges
        )

    if data.trailsEnabled ~= nil then
        trailsEnabled =
            data.trailsEnabled
    end

    if data.alertsEnabled ~= nil then
        alertsEnabled =
            data.alertsEnabled
    end

    debugLog(
        "Settings loaded: airport=" ..
        airports[airportIndex].icao ..
        ", range=" ..
        tostring(ranges[rangeIndex]) ..
        "NM, trails=" ..
        tostring(trailsEnabled) ..
        ", alerts=" ..
        tostring(alertsEnabled)
    )
end

--------------------------------------------------
-- API requests
--------------------------------------------------

function currentProvider()
    return API_PROVIDERS[providerIndex]
end


function switchProvider(reason)
    providerIndex =
        providerIndex %
        #API_PROVIDERS + 1

    successfulPolls = 0

    debugWarning(
        "Switching API provider to " ..
        currentProvider().name ..
        " because " ..
        tostring(reason)
    )
end


function aircraftRequestUrl(
    airport,
    radius
)
    local provider = currentProvider()

    if provider.style == "fi" then
        return provider.base ..
            tostring(airport.lat) ..
            "/lon/" ..
            tostring(airport.lon) ..
            "/dist/" ..
            tostring(radius)
    end

    return provider.base ..
        tostring(airport.lat) ..
        "/" ..
        tostring(airport.lon) ..
        "/" ..
        tostring(radius)
end


function requestAircraft()
    if gdt.Wifi0.AccessDenied then
        setNetworkState(
            "error",
            "permission denied"
        )

        lastError =
            "NETWORK DENIED"

        debugError(
            "WiFi AccessDenied is true"
        )

        retryCount = retryCount + 1
        nextPoll = gdt.CPU0.Time + math.min(
            RETRY_DELAY * retryCount,
            MAX_RETRY_DELAY
        )

        return false
    end

    if requestHandle then
        debugWarning(
            "Request ignored because handle " ..
            tostring(requestHandle) ..
            " is still active"
        )

        return false
    end

    if providerCooldowns[providerIndex] >
        gdt.CPU0.Time then

        local foundProvider = false
        local earliestCooldown = math.huge

        for index = 1,
            #API_PROVIDERS do

            earliestCooldown = math.min(
                earliestCooldown,
                providerCooldowns[index]
            )

            if providerCooldowns[index] <=
                gdt.CPU0.Time then

                providerIndex = index
                foundProvider = true
                break
            end
        end

        if not foundProvider then
            nextPoll = earliestCooldown

            setNetworkState(
                "waiting",
                "all providers cooling down"
            )

            debugWarning(
                "All API providers are cooling down"
            )

            return false
        end
    end

    local airport =
        airports[airportIndex]

    local radius = DATA_RADIUS

    local url =
        aircraftRequestUrl(
            airport,
            radius
        )

    requestProviderIndex = providerIndex

    requestCount = requestCount + 1

    setNetworkState(
        "loading",
        "request starting"
    )

    requestStartedAt =
        gdt.CPU0.Time

    debugLog(
        "Starting request #" ..
        tostring(requestCount)
    )

    debugLog(
        "Provider: " ..
        currentProvider().name
    )

    debugLog(
        "Airport: " ..
        airport.icao ..
        " " ..
        airport.name
    )

    debugLog(
        "Coordinates: " ..
        tostring(airport.lat) ..
        ", " ..
        tostring(airport.lon)
    )

    debugLog(
        "Radius: " ..
        tostring(radius) ..
        " NM data cache; display=" ..
        tostring(ranges[rangeIndex]) ..
        " NM"
    )

    debugLog("URL: " .. url)

    local success, handle = pcall(
        function()
            return gdt.Wifi0:WebGet(url)
        end
    )

    if not success then
        requestHandle = nil
        requestProviderIndex = nil
        requestStartedAt = 0
        retryCount = retryCount + 1

        local delay = math.min(
            RETRY_DELAY * retryCount,
            MAX_RETRY_DELAY
        )

        setNetworkState("error", "WebGet exception")
        lastError = "REQUEST FAILED"
        switchProvider("WebGet exception")
        nextPoll = gdt.CPU0.Time + delay

        debugError(
            "WebGet exception: " .. tostring(handle)
        )
        debugLog(
            "Retry scheduled in " .. tostring(delay) .. " seconds"
        )

        return false
    end

    requestHandle = handle

    if requestHandle == nil then
        requestProviderIndex = nil
        requestStartedAt = 0
        retryCount = retryCount + 1

        local delay = math.min(
            RETRY_DELAY * retryCount,
            MAX_RETRY_DELAY
        )

        setNetworkState("error", "no request handle")
        lastError = "NO REQUEST HANDLE"
        switchProvider("no request handle")
        nextPoll = gdt.CPU0.Time + delay

        debugError(
            "WebGet returned nil. WiFi may not be ready yet."
        )
        debugLog(
            "Retry scheduled in " .. tostring(delay) .. " seconds"
        )

        return false
    end

    debugLog(
        "Request handle: " ..
        tostring(requestHandle)
    )

    -- Prevent the poll timer from attempting another request while this
    -- request is active. A successful response schedules the normal poll.
    nextPoll = math.huge

    return true
end


function scheduleSuccessfulPoll()
    successfulPolls = successfulPolls + 1
    rateLimitedUntil = 0
    lastSuccessfulRefresh = gdt.CPU0.Time

    if successfulPolls >= SPEED_UP_AFTER_SUCCESSES then
        successfulPolls = 0
        adaptivePollInterval = math.max(
            MIN_POLL_INTERVAL,
            adaptivePollInterval -
            POLL_SPEEDUP_STEP
        )
    end

    nextPoll =
        gdt.CPU0.Time +
        adaptivePollInterval

    debugLog(
        "Adaptive poll interval: " ..
        tostring(adaptivePollInterval) ..
        " seconds"
    )
end


function scheduleFailedPoll(
    responseCode,
    failedProvider
)
    successfulPolls = 0

    if responseCode == 429 then
        adaptivePollInterval = math.min(
            MAX_POLL_INTERVAL,
            math.max(
                45,
                adaptivePollInterval * 3
            )
        )

        providerCooldowns[
            failedProvider or providerIndex
        ] =
            gdt.CPU0.Time +
            adaptivePollInterval

        rateLimitedUntil =
            providerCooldowns[
                failedProvider or providerIndex
            ]

        switchProvider("HTTP 429")
        nextPoll =
            gdt.CPU0.Time +
            RETRY_DELAY

        lastError =
            "RATE LIMIT " ..
            tostring(adaptivePollInterval) ..
            "S"

        debugWarning(
            "HTTP 429: provider cooling down for " ..
            tostring(adaptivePollInterval) ..
            " seconds; alternate provider retry in " ..
            tostring(RETRY_DELAY) ..
            " seconds"
        )
    else
        switchProvider(
            "HTTP " ..
            tostring(responseCode)
        )

        nextPoll =
            gdt.CPU0.Time +
            RETRY_DELAY
    end
end


function processApiResponse(event)
    local completedHandle =
        requestHandle

    local completedProvider =
        requestProviderIndex or
        providerIndex

    requestHandle = nil
    requestProviderIndex = nil
    requestStartedAt = 0
    responseCount = responseCount + 1
    retryCount = 0
    initialLoadComplete = true

    local responseCode =
        safeNumber(
            event.ResponseCode,
            0
        )

    local textLength = 0

    if event.Text then
        textLength = #event.Text
    end

    debugLog(
        "Response #" ..
        tostring(responseCount) ..
        " received"
    )

    debugLog(
        "Completed handle: " ..
        tostring(completedHandle)
    )

    debugLog(
        "Completed provider: " ..
        API_PROVIDERS[
            completedProvider
        ].name
    )

    debugLog(
        "Event handle: " ..
        tostring(event.RequestHandle)
    )

    debugLog(
        "HTTP status: " ..
        tostring(responseCode)
    )

    debugLog(
        "IsError: " ..
        tostring(event.IsError)
    )

    debugLog(
        "Content-Type: " ..
        tostring(event.ContentType)
    )

    debugLog(
        "Response length: " ..
        tostring(textLength)
    )

    debugLog(
        "Error type: " ..
        tostring(event.ErrorType)
    )

    debugLog(
        "Error message: " ..
        tostring(event.ErrorMessage)
    )

    if DEBUG_RESPONSE_PREVIEW
        and textLength > 0 then

        debugLog(
            "Response preview: " ..
            string.sub(
                event.Text,
                1,
                RESPONSE_PREVIEW_LENGTH
            )
        )
    end

    if event.IsError
        or responseCode < 200
        or responseCode >= 300 then

        setNetworkState(
            "error",
            "HTTP failure"
        )

        lastError =
            "HTTP " ..
            tostring(responseCode)

        if trim(event.ErrorMessage) ~= "" then
            lastError =
                lastError ..
                " " ..
                tostring(
                    event.ErrorMessage
                )
        end

        scheduleFailedPoll(
            responseCode,
            completedProvider
        )
        debugError(lastError)
        return
    end

    providerIndex = completedProvider

    if not event.Text
        or event.Text == "" then

        setNetworkState(
            "error",
            "empty body"
        )

        lastError =
            "EMPTY RESPONSE"

        scheduleFailedPoll(
            responseCode,
            completedProvider
        )

        debugError(lastError)
        return
    end

    debugLog(
        "Attempting JSON decode"
    )

    local success, data =
        pcall(
            json.decode,
            event.Text
        )

    if not success then
        setNetworkState(
            "error",
            "JSON exception"
        )

        lastError = "JSON ERROR"

        scheduleFailedPoll(
            responseCode,
            completedProvider
        )

        debugError(
            "JSON decoder exception: " ..
            tostring(data)
        )

        return
    end

    if type(data) ~= "table" then
        setNetworkState(
            "error",
            "wrong JSON type"
        )

        lastError = "BAD JSON TYPE"

        scheduleFailedPoll(
            responseCode,
            completedProvider
        )

        debugError(
            "Decoded JSON type was " ..
            tostring(type(data))
        )

        return
    end

    debugLog(
        "JSON decoded successfully"
    )

    debugLog(
        "API message: " ..
        tostring(data.msg)
    )

    debugLog(
        "API total field: " ..
        tostring(data.total)
    )

    debugLog(
        "Aircraft array type: " ..
        tostring(type(data.ac))
    )

    local oldHex = selectedHex
    local accepted = 0
    local outside = 0
    local invalid = 0

    allAircraft = {}

    if type(data.ac) == "table" then
        debugLog(
            "Raw aircraft count: " ..
            tostring(#data.ac)
        )

        for _, source in ipairs(data.ac) do
            local item =
                processAircraft(source)

            if not item then
                invalid = invalid + 1

            elseif item.distance >
                DATA_RADIUS then

                outside = outside + 1

                if DEBUG_AIRCRAFT then
                    debugWarning(
                        "Outside data radius: " ..
                        tostring(
                            item.callsign
                        ) ..
                        " at " ..
                        string.format(
                            "%.2f",
                            item.distance
                        ) ..
                        " NM"
                    )
                end

            else
                accepted = accepted + 1

                table.insert(
                    allAircraft,
                    item
                )

                if DEBUG_AIRCRAFT then
                    debugLog(
                        "Accepted: " ..
                        tostring(
                            item.callsign
                        ) ..
                        ", hex=" ..
                        tostring(item.hex) ..
                        ", type=" ..
                        tostring(
                            item.aircraftType
                        ) ..
                        ", alt=" ..
                        tostring(
                            item.altitude
                        ) ..
                        ", speed=" ..
                        tostring(item.speed) ..
                        ", rate=" ..
                        tostring(
                            item.verticalRate
                        ) ..
                        ", distance=" ..
                        string.format(
                            "%.2f",
                            item.distance
                        ) ..
                        ", status=" ..
                        item.status
                    )
                end
            end
        end
    else
        debugWarning(
            "Response contained no ac table"
        )
    end

    debugLog(
        "Aircraft processing complete: accepted=" ..
        tostring(accepted) ..
        ", outside=" ..
        tostring(outside) ..
        ", invalid=" ..
        tostring(invalid)
    )

    updateTrails(allAircraft)
    applyRangeFilter()

    if followMode and oldHex then
        local item, index =
            findAircraftByHex(oldHex)

        if item then
            aircraftIndex = index
            selectedHex = oldHex

            debugLog(
                "Follow target retained: " ..
                tostring(oldHex)
            )

        elseif #aircraft > 0 then
            aircraftIndex = 1
            selectedHex =
                aircraft[1].hex

            followMode = false

            debugWarning(
                "Follow target disappeared; selected first aircraft"
            )

        else
            selectedHex = nil
            followMode = false

            debugWarning(
                "Follow target disappeared and no aircraft remain"
            )
        end
    else
        aircraftIndex =
            clamp(
                aircraftIndex,
                1,
                math.max(#aircraft, 1)
            )

        if #aircraft > 0 then
            selectedHex =
                aircraft[
                    aircraftIndex
                ].hex
        else
            selectedHex = nil
        end
    end

    setNetworkState(
        "online",
        "response processed"
    )

    scheduleSuccessfulPoll()

    debugLog(
        "Next poll scheduled for CPU time " ..
        string.format(
            "%.1f",
            nextPoll
        )
    )
end


function eventChannel1(sender, event)
    debugLog(
        "WiFi event received: type=" ..
        tostring(event.Type) ..
        ", handle=" ..
        tostring(event.RequestHandle) ..
        ", activeHandle=" ..
        tostring(requestHandle)
    )

    if requestHandle
        and event.RequestHandle ==
        requestHandle then

        processApiResponse(event)
    else
        debugWarning(
            "Ignored WiFi event for non-active handle " ..
            tostring(event.RequestHandle)
        )
    end
end

--------------------------------------------------
-- Request timeout
--------------------------------------------------

function updateRequestTimeout()
    if not requestHandle then
        return
    end

    local elapsed =
        gdt.CPU0.Time -
        requestStartedAt

    local timeoutLimit = REQUEST_TIMEOUT

    if not initialLoadComplete then
        timeoutLimit = INITIAL_REQUEST_TIMEOUT
    end

    if elapsed < timeoutLimit then
        return
    end

    timeoutCount = timeoutCount + 1

    debugError(
        "Request timeout #" ..
        tostring(timeoutCount) ..
        ": handle=" ..
        tostring(requestHandle) ..
        ", elapsed=" ..
        string.format(
            "%.1f",
            elapsed
        ) ..
        " seconds, limit=" ..
        tostring(timeoutLimit) ..
        " seconds"
    )

    local aborted =
        gdt.Wifi0:WebAbort(
            requestHandle
        )

    debugLog(
        "WebAbort result: " ..
        tostring(aborted)
    )

    local timedOutProvider =
        requestProviderIndex or
        providerIndex

    requestHandle = nil
    requestProviderIndex = nil
    requestStartedAt = 0

    setNetworkState(
        "error",
        "request timeout"
    )

    lastError = "API TIMEOUT"

    switchProvider(
        API_PROVIDERS[
            timedOutProvider
        ].name ..
        " timeout"
    )

    retryCount = retryCount + 1

    local delay = math.min(
        RETRY_DELAY * retryCount,
        10
    )

    nextPoll =
        gdt.CPU0.Time + delay

    debugLog(
        "Retry scheduled in " ..
        tostring(delay) ..
        " seconds"
    )
end

--------------------------------------------------
-- Controls
--------------------------------------------------

function resetAirportView()
    debugLog(
        "Resetting airport view"
    )

    aircraft = {}
    allAircraft = {}
    trails = {}

    aircraftIndex = 1
    selectedHex = nil
    followMode = false

    if requestHandle then
        debugLog(
            "Aborting active request " ..
            tostring(requestHandle)
        )

        local aborted =
            gdt.Wifi0:WebAbort(
                requestHandle
            )

        debugLog(
            "WebAbort result: " ..
            tostring(aborted)
        )

        requestHandle = nil
        requestProviderIndex = nil
    end

    requestStartedAt = 0
    nextPoll = 0
end


function handleAirportKnob()
    local newIndex =
        knobIndex(
            gdt.Knob0,
            #airports
        )

    if lastAirportKnob == nil then
        lastAirportKnob = newIndex

        debugLog(
            "Initial airport knob index: " ..
            tostring(newIndex)
        )

        return
    end

    if newIndex ~= lastAirportKnob then
        debugLog(
            "Airport knob changed: " ..
            tostring(lastAirportKnob) ..
            " -> " ..
            tostring(newIndex)
        )

        lastAirportKnob = newIndex
        airportIndex = newIndex

        debugLog(
            "Selected airport: " ..
            airports[airportIndex].icao ..
            " " ..
            airports[airportIndex].name
        )

        resetAirportView()
        saveSettings()
    end
end


function handleAircraftKnob()
    if #aircraft == 0 then
        aircraftIndex = 1
        return
    end

    local newIndex =
        knobIndex(
            gdt.Knob1,
            #aircraft
        )

    if lastAircraftKnob == nil then
        lastAircraftKnob = newIndex

        debugLog(
            "Initial aircraft knob index: " ..
            tostring(newIndex)
        )
    end

    if newIndex ~= lastAircraftKnob then
        debugLog(
            "Aircraft knob changed: " ..
            tostring(lastAircraftKnob) ..
            " -> " ..
            tostring(newIndex)
        )

        lastAircraftKnob = newIndex
        aircraftIndex = newIndex

        selectedHex =
            aircraft[newIndex].hex

        followMode = false

        debugLog(
            "Selected aircraft: " ..
            tostring(
                aircraft[newIndex].callsign
            ) ..
            ", hex=" ..
            tostring(selectedHex)
        )
    end
end


function setRadarRange(newIndex)
    if rangeIndex == newIndex then
        return
    end

    rangeIndex = newIndex

    debugLog(
        "Radar range changed to " ..
        tostring(ranges[rangeIndex]) ..
        " NM"
    )

    applyRangeFilter()
    lastAircraftKnob = nil
    saveSettings()
end


function handleScreenButtons()
    local buttons = {
        gdt.ScreenButton0,
        gdt.ScreenButton1,
        gdt.ScreenButton2,
        gdt.ScreenButton3,
        gdt.ScreenButton4,
        gdt.ScreenButton5
    }

    for index = 1, 4 do
        if buttons[index].ButtonDown then
            setRadarRange(index)
        end
    end

    if buttons[5].ButtonDown then
        trailsEnabled = not trailsEnabled

        debugLog(
            "Trails enabled: " ..
            tostring(trailsEnabled)
        )

        if not trailsEnabled then
            trails = {}
        end

        saveSettings()
    end

    if buttons[6].ButtonDown then
        alertsEnabled = not alertsEnabled

        debugLog(
            "Alerts enabled: " ..
            tostring(alertsEnabled)
        )

        saveSettings()
    end
end


function handleStick()
    if ranges[rangeIndex] >= 10 then
        panOffsetX = 0
        panOffsetY = 0
        return
    end

    local stickX = gdt.Stick0.X
    local stickY = gdt.Stick0.Y

    if math.abs(stickX) < PAN_DEADZONE then
        stickX = 0
    end

    if math.abs(stickY) < PAN_DEADZONE then
        stickY = 0
    end

    if stickX == 0 and stickY == 0 then
        return
    end

    local maxPan =
        10 - ranges[rangeIndex]

    panOffsetX = clamp(
        panOffsetX + stickX * PAN_SPEED,
        -maxPan,
        maxPan
    )

    panOffsetY = clamp(
        panOffsetY - stickY * PAN_SPEED,
        -maxPan,
        maxPan
    )
end


function handleButtons()
    if gdt.LedButton0.ButtonDown then
        debugLog(
            "Manual refresh button pressed"
        )

        if requestHandle then
            debugWarning(
                "Refresh ignored: request " ..
                tostring(requestHandle) ..
                " is already active"
            )

        elseif providerCooldowns[1] >
            gdt.CPU0.Time
            and providerCooldowns[2] >
            gdt.CPU0.Time then

            local nextAvailable = math.min(
                providerCooldowns[1],
                providerCooldowns[2]
            )

            debugWarning(
                "Refresh ignored: all providers cooling down for " ..
                tostring(
                    math.ceil(
                        nextAvailable -
                        gdt.CPU0.Time
                    )
                ) ..
                " seconds remaining"
            )

        else
            nextPoll = gdt.CPU0.Time

            debugLog(
                "Manual refresh queued"
            )
        end
    end


end

--------------------------------------------------
-- Shared drawing helper
--------------------------------------------------

function drawCenteredText(
    video,
    y,
    text,
    textColor
)
    local textWidth =
        #text * 4

    local x =
        math.floor(
            (
                video.Width -
                textWidth
            ) / 2
        )

    video:DrawText(
        vec2(math.max(x, 0), y),
        font,
        text,
        textColor,
        color.clear
    )
end

--------------------------------------------------
-- Radar
--------------------------------------------------

function drawRunway(video, heading)
    local centerX =
        video.Width / 2

    local centerY =
        video.Height / 2

    local length =
        math.min(
            video.Width,
            video.Height
        ) * 0.22

    local radians =
        math.rad(heading)

    local dx =
        math.sin(radians) *
        length

    local dy =
        -math.cos(radians) *
        length

    video:DrawLine(
        vec2(
            centerX - dx,
            centerY - dy
        ),
        vec2(
            centerX + dx,
            centerY + dy
        ),
        GRAY
    )
end


function drawMapPath(
    video,
    path,
    pathColor,
    thickness
)
    for index = 2, #path do
        local first = path[index - 1]
        local second = path[index]

        local x1, y1 = radarOffsetPosition(
            first[1],
            first[2],
            video.Width,
            video.Height
        )

        local x2, y2 = radarOffsetPosition(
            second[1],
            second[2],
            video.Width,
            video.Height
        )

        local margin = 4

        if not (
            (x1 < -margin and x2 < -margin)
            or (x1 > video.Width + margin and x2 > video.Width + margin)
            or (y1 < -margin and y2 < -margin)
            or (y1 > video.Height + margin and y2 > video.Height + margin)
        ) then
            video:DrawLine(
                vec2(x1, y1),
                vec2(x2, y2),
                pathColor
            )

            if thickness and thickness > 1 then
                video:DrawLine(
                    vec2(x1 + 1, y1),
                    vec2(x2 + 1, y2),
                    pathColor
                )

                video:DrawLine(
                    vec2(x1, y1 + 1),
                    vec2(x2, y2 + 1),
                    pathColor
                )
            end
        end
    end
end


function drawMapLayer(
    video,
    map,
    layerName,
    layerColor,
    thickness
)
    local paths = map[layerName]

    if not paths then
        return
    end

    for _, path in ipairs(paths) do
        drawMapPath(
            video,
            path,
            layerColor,
            thickness
        )
    end
end


function drawGeographicMap(video)
    local airport = airports[airportIndex]
    local map = airportMaps[airport.icao]

    if not map then
        debugWarning(
            "No geographic map for " ..
            airport.icao
        )
        return false
    end

    drawMapLayer(
        video,
        map,
        "water",
        MAP_WATER,
        1
    )

    drawMapLayer(
        video,
        map,
        "road",
        MAP_ROAD,
        1
    )

    drawMapLayer(
        video,
        map,
        "boundary",
        MAP_BOUNDARY,
        1
    )

    if ranges[rangeIndex] <= 5 then
        drawMapLayer(
            video,
            map,
            "apron",
            MAP_APRON,
            1
        )
    end

    if ranges[rangeIndex] <= 3 then
        drawMapLayer(
            video,
            map,
            "building",
            MAP_BUILDING,
            1
        )

        drawMapLayer(
            video,
            map,
            "taxiway",
            MAP_TAXIWAY,
            1
        )
    end

    drawMapLayer(
        video,
        map,
        "runway",
        MAP_RUNWAY,
        2
    )

    return true
end


function drawTrails(video)
    if not trailsEnabled then
        return
    end

    for _, trail in pairs(trails) do
        for index = 2, #trail do
            local first =
                trail[index - 1]

            local second =
                trail[index]

            local x1, y1 =
                radarPosition(
                    first.lat,
                    first.lon,
                    video.Width,
                    video.Height
                )

            local x2, y2 =
                radarPosition(
                    second.lat,
                    second.lon,
                    video.Width,
                    video.Height
                )

            video:DrawLine(
                vec2(x1, y1),
                vec2(x2, y2),
                DIM_GREEN
            )
        end
    end
end


function drawAircraftSymbol(
    video,
    item,
    selected
)
    local x, y =
        radarPosition(
            item.lat,
            item.lon,
            video.Width,
            video.Height
        )

    x = math.floor(x)
    y = math.floor(y)

    if x < 1
        or x >= video.Width - 1
        or y < 1
        or y >= video.Height - 1 then

        return
    end

    local symbolColor = WHITE

    if item.status == "ARR" then
        symbolColor = GREEN
    elseif item.status == "DEP" then
        symbolColor = BLUE
    elseif item.status == "GND" then
        symbolColor = GRAY
    end

    if item.squawk == "7500"
        or item.squawk == "7600"
        or item.squawk == "7700" then

        symbolColor = RED
    end

    if selected then
        video:DrawCircle(
            vec2(x, y),
            4,
            AMBER
        )
    end

    local radians =
        math.rad(item.heading)

    local dx =
        math.sin(radians) * 3

    local dy =
        -math.cos(radians) * 3

    video:DrawLine(
        vec2(x - dx, y - dy),
        vec2(x + dx, y + dy),
        symbolColor
    )

    video:FillRect(
        vec2(x - 1, y - 1),
        vec2(x + 1, y + 1),
        symbolColor
    )

    if selected then
        local labelX = clamp(
            x + 5,
            1,
            video.Width - 33
        )

        local labelY = clamp(
            y - 3,
            9,
            video.Height - 7
        )

        video:DrawText(
            vec2(labelX, labelY),
            font,
            shortText(item.callsign, 8),
            AMBER,
            color.clear
        )
    end
end


function drawRadar()
    local video =
        gdt.VideoChip0

    local width = video.Width
    local height = video.Height

    video:RenderOnScreen()
    video:Clear(BLACK)

    local hasGeographicMap =
        drawGeographicMap(video)

    local center =
        vec2(
            width / 2,
            height / 2
        )

    local radius =
        math.min(width, height) /
        2 - 5

    video:DrawCircle(
        center,
        radius,
        DIM_GREEN
    )

    video:DrawCircle(
        center,
        radius * 0.66,
        DARK_GREEN
    )

    video:DrawCircle(
        center,
        radius * 0.33,
        DARK_GREEN
    )

    video:DrawLine(
        vec2(width / 2, 5),
        vec2(
            width / 2,
            height - 2
        ),
        DARK_GREEN
    )

    video:DrawLine(
        vec2(2, height / 2),
        vec2(
            width - 2,
            height / 2
        ),
        DARK_GREEN
    )

    if not hasGeographicMap then
        for _, heading in ipairs(
            airports[airportIndex].runways
        ) do
            drawRunway(video, heading)
        end
    end

    drawTrails(video)

    local selected =
        selectedAircraft()

    for _, item in ipairs(aircraft) do
        drawAircraftSymbol(
            video,
            item,
            selected
                and item.hex ==
                selected.hex
        )
    end

    video:DrawText(
        vec2(1, 1),
        font,
        airports[airportIndex].icao,
        GREEN,
        color.clear
    )

    video:DrawText(
        vec2(width - 15, 1),
        font,
        tostring(
            ranges[rangeIndex]
        ) .. "NM",
        GREEN,
        color.clear
    )

    video:DrawText(
        vec2(1, height - 7),
        font,
        "OPENSTREETMAP",
        GRAY,
        color.clear
    )
end

--------------------------------------------------
-- Traffic list
--------------------------------------------------

function drawTrafficBoard()
    local video =
        gdt.VideoChip1

    video:RenderOnScreen()
    video:Clear(BLACK)

    video:DrawText(
        vec2(1, 1),
        font,
        airports[airportIndex].icao ..
        " " ..
        tostring(#aircraft) ..
        " AC",
        GREEN,
        color.clear
    )

    video:DrawLine(
        vec2(0, 8),
        vec2(
            video.Width - 1,
            8
        ),
        DARK_GREEN
    )

    video:DrawText(
        vec2(1, 10),
        font,
        " CALLSIGN S   NM ALT  GS",
        DIM_GREEN,
        color.clear
    )

    if #aircraft == 0 then
        local message

        if networkState == "loading" then
            message = "SCANNING..."
        elseif networkState == "error" then
            message = "API ERROR"
        else
            message = "NO TRAFFIC"
        end

        drawCenteredText(
            video,
            32,
            message,
            networkState == "error"
                and RED
                or GRAY
        )

        return
    end

    local visibleRows = 6

    local first =
        clamp(
            aircraftIndex - 2,
            1,
            math.max(
                #aircraft - visibleRows + 1,
                1
            )
        )

    local row = 0

    for index = first,
        math.min(
            first + visibleRows - 1,
            #aircraft
        ) do

        local item =
            aircraft[index]

        local y =
            18 + row * 7

        local textColor =
            index == aircraftIndex
                and AMBER
                or WHITE

        local prefix =
            index == aircraftIndex
                and ">"
                or " "

        local status =
            item.status == "ARR" and "A"
            or item.status == "DEP" and "D"
            or item.status == "GND" and "G"
            or "O"

        local line = string.format(
            "%s%-7s %s %4.1f %3s %3d",
            prefix,
            shortText(item.callsign, 7),
            status,
            item.distance,
            formatAltitude(item.altitude),
            math.min(
                999,
                math.floor(item.speed)
            )
        )

        video:DrawText(
            vec2(1, y),
            font,
            shortText(line, 28),
            textColor,
            color.clear
        )

        row = row + 1
    end
end

--------------------------------------------------
-- Aircraft details
--------------------------------------------------

function drawAircraftDetails()
    local video =
        gdt.VideoChip2

    video:RenderOnScreen()
    video:Clear(BLACK)

    local item =
        selectedAircraft()

    if not item then
        video:DrawText(
            vec2(1, 2),
            font,
            airports[
                airportIndex
            ].name,
            GREEN,
            color.clear
        )

        video:DrawText(
            vec2(65, 2),
            font,
            networkState == "error"
                and "API ERROR"
                or "NO AIRCRAFT",
            networkState == "error"
                and RED
                or GRAY,
            color.clear
        )

        if networkState == "error" then
            video:DrawText(
                vec2(1, 18),
                font,
                shortText(
                    lastError,
                    15
                ),
                RED,
                color.clear
            )
        end

        return
    end

    local statusColor =
        item.status == "ARR"
            and GREEN
        or item.status == "DEP"
            and BLUE
        or WHITE

    local isEmergency =
        item.squawk == "7500"
        or item.squawk == "7600"
        or item.squawk == "7700"

    local lines = {
        shortText(item.callsign, 8) ..
            " " .. item.status ..
            " " ..
            shortText(item.registration, 6) ..
            " " ..
            shortText(item.aircraftType, 4),

        string.format(
            "ALT%3s GS%03d HDG%03d",
            formatAltitude(item.altitude),
            math.min(
                999,
                math.floor(item.speed)
            ),
            math.floor(item.heading) % 360
        ),

        string.format(
            "NM%4.1f BRG%03d VR%+d SQ%s",
            item.distance,
            math.floor(item.bearing) % 360,
            clamp(
                math.floor(item.verticalRate),
                -9999,
                9999
            ),
            shortText(item.squawk, 4)
        ),

        shortText(item.description, 12) ..
            " FOL " ..
            (followMode and "ON" or "OFF") ..
            " EM " ..
            shortText(item.emergency, 4)
    }

    local lineColors = {
        statusColor,
        WHITE,
        isEmergency and RED or WHITE,
        followMode and AMBER or GRAY
    }

    for index, line in ipairs(lines) do
        video:DrawText(
            vec2(1, 1 + (index - 1) * 8),
            font,
            shortText(line, 28),
            lineColors[index],
            color.clear
        )
    end
end

--------------------------------------------------
-- Screen buttons and LED buttons
--------------------------------------------------

function hasEmergencyAircraft()
    for _, plane in ipairs(aircraft) do
        if plane.squawk == "7500"
            or plane.squawk == "7600"
            or plane.squawk == "7700" then

            return true
        end
    end

    return false
end


function drawScreenButton(
    video,
    button,
    topText,
    bottomText,
    active,
    warning
)
    local background = DARK_GREEN
    local textColor = GREEN

    if active then
        background = DIM_GREEN
        textColor = WHITE
    end

    if warning then
        background = RED
        textColor = WHITE
    end

    if button.ButtonState then
        background = AMBER
        textColor = BLACK
    end

    video:FillRect(
        button.Offset,
        button.Offset +
            vec2(
                button.Width - 1,
                button.Height - 1
            ),
        background
    )

    local topX = math.floor(
        (button.Width - #topText * 4) /
        2
    )

    local bottomX = math.floor(
        (button.Width - #bottomText * 4) /
        2
    )

    video:DrawText(
        button.Offset +
            vec2(math.max(topX, 0), 1),
        font,
        topText,
        textColor,
        color.clear
    )

    video:DrawText(
        button.Offset +
            vec2(math.max(bottomX, 0), 8),
        font,
        bottomText,
        textColor,
        color.clear
    )
end


function drawControlButtons()
    local video = gdt.VideoChip3
    local emergency =
        alertsEnabled and
        hasEmergencyAircraft()

    video:RenderOnScreen()
    video:Clear(BLACK)

    drawScreenButton(
        video,
        gdt.ScreenButton0,
        "1",
        "NM",
        rangeIndex == 1,
        false
    )

    drawScreenButton(
        video,
        gdt.ScreenButton1,
        "3",
        "NM",
        rangeIndex == 2,
        false
    )

    drawScreenButton(
        video,
        gdt.ScreenButton2,
        "5",
        "NM",
        rangeIndex == 3,
        false
    )

    drawScreenButton(
        video,
        gdt.ScreenButton3,
        "10",
        "NM",
        rangeIndex == 4,
        false
    )

    drawScreenButton(
        video,
        gdt.ScreenButton4,
        "TRL",
        trailsEnabled and "ON" or "OFF",
        trailsEnabled,
        false
    )

    drawScreenButton(
        video,
        gdt.ScreenButton5,
        "ALT",
        alertsEnabled and "ON" or "OFF",
        alertsEnabled,
        emergency
    )
end


function updateLedButtons()
    local flash =
        math.floor(
            gdt.CPU0.Time * 4
        ) % 2 == 0

    gdt.LedButton0.LedColor =
        networkState == "error"
            and RED
            or GREEN

    gdt.LedButton0.LedState =
        networkState == "loading"
            and flash
        or networkState == "online"
end

--------------------------------------------------
-- Periodic debug status
--------------------------------------------------

function updateDebugStatus()
    if not DEBUG
        or gdt.CPU0.Time <
        nextDebugStatus then

        return
    end

    nextDebugStatus =
        gdt.CPU0.Time +
        DEBUG_STATUS_INTERVAL

    local selected =
        selectedAircraft()

    debugLog(
        "STATUS: state=" ..
        tostring(networkState) ..
        ", airport=" ..
        airports[airportIndex].icao ..
        ", range=" ..
        tostring(ranges[rangeIndex]) ..
        "NM, aircraft=" ..
        tostring(#aircraft) ..
        ", selected=" ..
        tostring(
            selected
            and selected.callsign
            or "none"
        ) ..
        ", follow=" ..
        tostring(followMode) ..
        ", requestHandle=" ..
        tostring(requestHandle) ..
        ", nextPoll=" ..
        string.format(
            "%.1f",
            nextPoll
        ) ..
        ", requests=" ..
        tostring(requestCount) ..
        ", responses=" ..
        tostring(responseCount) ..
        ", timeouts=" ..
        tostring(timeoutCount) ..
        ", pollInterval=" ..
        tostring(adaptivePollInterval) ..
        ", cooldown=" ..
        tostring(
            math.max(
                0,
                math.ceil(
                    rateLimitedUntil -
                    gdt.CPU0.Time
                )
            )
        ) ..
        ", provider=" ..
        currentProvider().name
    )
end

--------------------------------------------------
-- Drawing
--------------------------------------------------

function lcdLine(text)
    local value = string.sub(
        tostring(text),
        1,
        16
    )

    return value ..
        string.rep(
            " ",
            16 - #value
        )
end


function updateStatusLcd()
    local ageText = "--"

    if lastSuccessfulRefresh then
        ageText = string.format(
            "%02d",
            math.min(
                99,
                math.floor(
                    gdt.CPU0.Time -
                    lastSuccessfulRefresh
                )
            )
        )
    end

    local airborne = 0
    local ground = 0

    for _, item in ipairs(aircraft) do
        if item.status == "GND"
            or item.altitude == "ground" then

            ground = ground + 1
        else
            airborne = airborne + 1
        end
    end

    local topLine = string.format(
        "POLL %3ds AGE %2s",
        math.floor(adaptivePollInterval),
        ageText
    )

    local bottomLine = string.format(
        "AIR %03d GND %03d",
        math.min(airborne, 999),
        math.min(ground, 999)
    )

    gdt.Lcd0.BgColor =
        Color(55, 70, 60)

    gdt.Lcd0.TextColor = GREEN

    gdt.Lcd0.Text =
        lcdLine(topLine) ..
        lcdLine(bottomLine)
end


function drawAll()
    drawRadar()
    drawTrafficBoard()
    drawAircraftDetails()
    drawControlButtons()
    updateStatusLcd()
end

--------------------------------------------------
-- Startup
--------------------------------------------------

debugLog("Starting airport tracker")

debugLog(
    "Screen0: " ..
    tostring(gdt.VideoChip0.Width) ..
    "x" ..
    tostring(gdt.VideoChip0.Height)
)

debugLog(
    "Screen1: " ..
    tostring(gdt.VideoChip1.Width) ..
    "x" ..
    tostring(gdt.VideoChip1.Height)
)

debugLog(
    "Screen2: " ..
    tostring(gdt.VideoChip2.Width) ..
    "x" ..
    tostring(gdt.VideoChip2.Height)
)

debugLog(
    "Control buttons: " ..
    tostring(gdt.VideoChip3.Width) ..
    "x" ..
    tostring(gdt.VideoChip3.Height)
)

debugLog(
    "WiFi AccessDenied: " ..
    tostring(gdt.Wifi0.AccessDenied)
)

loadSettings()

lastAirportKnob =
    knobIndex(
        gdt.Knob0,
        #airports
    )

airportIndex =
    lastAirportKnob

debugLog(
    "Physical airport knob selected " ..
    airports[airportIndex].icao
)

nextPoll = gdt.CPU0.Time + STARTUP_DELAY

setNetworkState(
    "waiting",
    "startup delay"
)

debugLog(
    "Initial request scheduled in " ..
    tostring(STARTUP_DELAY) ..
    " seconds at CPU time " ..
    string.format("%.1f", nextPoll)
)

drawAll()

--------------------------------------------------
-- Main loop
--------------------------------------------------

function update()
    handleAirportKnob()
    handleAircraftKnob()
    handleScreenButtons()
    handleStick()
    handleButtons()

    updateRequestTimeout()

    if gdt.CPU0.Time >= nextPoll
        and not requestHandle then

        debugLog(
            "Poll timer reached"
        )

        requestAircraft()
    end

    drawTimer =
        drawTimer +
        gdt.CPU0.DeltaTime

    if drawTimer >= DRAW_INTERVAL then
        drawTimer =
            drawTimer -
            DRAW_INTERVAL

        drawAll()
    end

    updateLedButtons()
    updateDebugStatus()
end
