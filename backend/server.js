const express = require('express');
const axios = require('axios');
const app = express();
const PORT = process.env.PORT || 80;

// Public weather API. Swapped from Open-Meteo to MET Norway (api.met.no) to
// test whether the outbound failure is provider-specific or a general egress
// black-hole. No API key required, but MET requires a descriptive User-Agent.
const LATITUDE = process.env.WEATHER_LATITUDE || '17.385';
const LONGITUDE = process.env.WEATHER_LONGITUDE || '78.4867';
const WEATHER_URL = `https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=${LATITUDE}&lon=${LONGITUDE}`;

// Map a few common MET Norway symbol_codes to Open-Meteo WMO codes so the
// frontend's describeWeather() keeps working without changes.
function symbolToWmo(symbol) {
    if (!symbol) return undefined;
    const s = symbol.split('_')[0]; // strip _day/_night
    const map = {
        clearsky: 0, fair: 1, partlycloudy: 2, cloudy: 3, fog: 45,
        lightrain: 61, rain: 63, heavyrain: 65, lightsnow: 71, snow: 73,
        heavysnow: 75, rainshowers: 80, heavyrainshowers: 82, thunder: 95
    };
    return map[s];
}

app.get('/api/data', async (req, res) => {
    try {
        // Outbound call leaves the VNet through the NAT Gateway's static IP
        const response = await axios.get(WEATHER_URL, {
            timeout: 5000,
            headers: { 'User-Agent': 'az-sample-howden-weather/1.0 (https://github.com/howden/az-sample-03)' }
        });

        const ts = response.data?.properties?.timeseries?.[0];
        const details = ts?.data?.instant?.details || {};
        const symbol = ts?.data?.next_1_hours?.summary?.symbol_code
            || ts?.data?.next_6_hours?.summary?.symbol_code;

        const weather = {
            temperature: details.air_temperature,
            // MET reports wind in m/s; convert to km/h to match the frontend label
            windspeed: details.wind_speed != null ? Math.round(details.wind_speed * 3.6 * 10) / 10 : undefined,
            weathercode: symbolToWmo(symbol)
        };

        res.json({
            status: "Success",
            message: "Hello from the Container App Backend! (provider: api.met.no)",
            weatherSource: WEATHER_URL,
            location: { latitude: LATITUDE, longitude: LONGITUDE },
            weather,
            timestamp: new Date()
        });
    } catch (error) {
        console.error(`Weather fetch failed for ${WEATHER_URL}: ${error.message} (code=${error.code || 'n/a'})`);
        res.status(502).json({
            status: "Error",
            message: "Backend could not reach the public weather API via the NAT Gateway",
            error: error.message,
            timestamp: new Date()
        });
    }
});

app.listen(PORT, () => console.log(`Backend listening on port ${PORT}`));