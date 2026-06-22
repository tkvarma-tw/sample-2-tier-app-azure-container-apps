const express = require('express');
const axios = require('axios');
const app = express();
const PORT = process.env.PORT || 80;
const BACKEND_URL = process.env.BACKEND_URL;

// Open-Meteo weather codes -> human-readable summary
function describeWeather(code) {
    const map = {
        0: '☀️ Clear sky', 1: '🌤️ Mainly clear', 2: '⛅ Partly cloudy', 3: '☁️ Overcast',
        45: '🌫️ Fog', 48: '🌫️ Rime fog', 51: '🌦️ Light drizzle', 53: '🌦️ Drizzle',
        55: '🌧️ Dense drizzle', 61: '🌧️ Light rain', 63: '🌧️ Rain', 65: '🌧️ Heavy rain',
        71: '🌨️ Light snow', 73: '🌨️ Snow', 75: '❄️ Heavy snow', 80: '🌦️ Rain showers',
        81: '🌧️ Rain showers', 82: '⛈️ Violent rain showers', 95: '⛈️ Thunderstorm',
        96: '⛈️ Thunderstorm w/ hail', 99: '⛈️ Severe thunderstorm w/ hail'
    };
    return map[code] || `Code ${code}`;
}

app.get('/', async (req, res) => {
    try {
        // Fetch data from the Azure Container App backend (private, via VNet + Private DNS)
        const response = await axios.get(`${BACKEND_URL}/api/aggregated-data`);
        const data = response.data;
        const w = data.weather || {};

        res.send(`
            <html>
            <body style="font-family: Arial, sans-serif; margin: 40px; text-align: center;">
                <h1 style="color: #0078d4;">Azure End-to-End Connectivity Test</h1>
                <div style="border: 2px solid #22c55e; padding: 20px; border-radius: 8px; display: inline-block; background-color: #f0fdf4;">
                    <h2 style="color: #15803d; margin-top: 0;">✅ Connected to Backend</h2>
                    <p><strong>Frontend fetched data from:</strong> <code style="background: #e2e8f0; padding: 2px 6px;">${BACKEND_URL}</code></p>
                    <p style="color: #15803d;">${data.message || ''}</p>
                </div>

                <div style="border: 2px solid #0078d4; padding: 20px; border-radius: 8px; display: block; max-width: 420px; margin: 24px auto; background-color: #eff6ff;">
                    <h2 style="color: #0078d4; margin-top: 0;">🌦️ Live Weather (via NAT Gateway)</h2>
                    <p style="font-size: 42px; margin: 8px 0;">${w.temperature != null ? w.temperature + '°C' : '—'}</p>
                    <p style="font-size: 20px; margin: 4px 0;">${describeWeather(w.weathercode)}</p>
                    <p style="color: #475569;">💨 Wind: ${w.windspeed != null ? w.windspeed + ' km/h' : '—'} &nbsp;|&nbsp; 📍 ${data.location ? data.location.latitude + ', ' + data.location.longitude : ''}</p>
                    <p style="color: #94a3b8; font-size: 12px;">Backend fetched this from the public Open-Meteo API through the NAT Gateway's static egress IP.</p>
                </div>

                <details style="max-width: 480px; margin: 0 auto; text-align: left;">
                    <summary style="cursor: pointer; color: #64748b;">Raw backend response</summary>
                    <pre style="background: #27272a; color: #f4f4f5; padding: 15px; border-radius: 4px; overflow-x: auto;">${JSON.stringify(data, null, 2)}</pre>
                </details>
            </body>
            </html>
        `);
    } catch (error) {
        res.send(`
            <html>
            <body style="font-family: Arial, sans-serif; margin: 40px; text-align: center;">
                <h1 style="color: #0078d4;">Azure End-to-End Connectivity Test</h1>
                <div style="border: 2px solid #ef4444; padding: 20px; border-radius: 8px; display: inline-block; background-color: #fef2f2;">
                    <h2 style="color: #b91c1c; margin-top: 0;">❌ Connection Failed</h2>
                    <p><strong>Attempted to reach:</strong> <code>${BACKEND_URL}</code></p>
                    <p style="color: #dc2626;"><strong>Error:</strong> ${error.message}</p>
                </div>
            </body>
            </html>
        `);
    }
});

app.listen(PORT, () => console.log(`Frontend listening on port ${PORT}`));