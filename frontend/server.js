const express = require('express');
const axios = require('axios');
const app = express();
const PORT = process.env.PORT || 80;
const BACKEND_URL = process.env.BACKEND_URL;

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

app.use(express.json());

// --- HEALTH PROBE ENDPOINT ---
app.get('/health', (req, res) => {
    // A simple 200 OK response to indicate the service is running
    res.status(200).json({ 
        status: 'Healthy', 
        timestamp: new Date().toISOString() 
    });
});
// -----------------------------

app.post('/api/publish-event', async (req, res) => {
    try {
        const response = await axios.post(`${BACKEND_URL}/api/publish-event`, {
            details: 'Test event from frontend UI'
        }, { timeout: 5000 });
        res.json(response.data);
    } catch (error) {
        res.status(502).json({ status: 'Error', message: 'Failed to publish event', error: error.message });
    }
});

app.get('/api/event-status', async (req, res) => {
    try {
        const response = await axios.get(`${BACKEND_URL}/api/event-status`, { timeout: 5000 });
        res.json({
            ...response.data,
            _servedFrom: {
                region: process.env.REGION_NAME || 'unknown',
                instanceId: (process.env.WEBSITE_INSTANCE_ID || 'unknown').slice(0, 12),
                zone: process.env.WEBSITE_ZONE_ID != null ? `AZ ${parseInt(process.env.WEBSITE_ZONE_ID) + 1}` : 'unknown'
            }
        });
    } catch (error) {
        res.status(502).json({ status: 'Error', message: 'Failed to fetch event status', error: error.message });
    }
});

app.get('/', async (req, res) => {
    try {
        const response = await axios.get(`${BACKEND_URL}/api/aggregated-data`, { timeout: 5000 });
        const data = response.data;
        const w = data.weather || {};

        // APIM stamps this response header via an outbound policy; the aggregator
        // never sets it, so its presence proves the call traversed APIM.
        const apimName = response.headers['x-served-via-apim'];
        const apimBadge = apimName
            ? `<p style="color:#15803d;">✅ Routed through Azure APIM: <code style="background:#e2e8f0; padding:2px 6px;">${apimName}</code></p>`
            : `<p style="color:#b45309;">⚠️ APIM marker header not present — request may not have traversed APIM.</p>`;

        res.send(`
            <html>
            <body style="font-family: Arial, sans-serif; margin: 40px; text-align: center;">
                <h1 style="color: #0078d4;">Azure End-to-End Connectivity Test</h1>
                <div style="display: grid; gap: 20px; justify-content: center;">
                    <div style="border: 2px solid #22c55e; padding: 20px; border-radius: 8px; background-color: #f0fdf4; max-width: 540px; text-align: left;">
                        <h2 style="color: #15803d; margin-top: 0;">✅ Connected to Backend</h2>
                        <p><strong>Frontend fetched data from:</strong> <code style="background: #e2e8f0; padding: 2px 6px;">${BACKEND_URL}</code></p>
                        ${apimBadge}
                        <p style="color: #15803d;">${data.message || ''}</p>
                    </div>

                    <div style="border: 2px solid #0078d4; padding: 20px; border-radius: 8px; background-color: #eff6ff; max-width: 540px; text-align: left;">
                        <h2 style="color: #0078d4; margin-top: 0;">🌦️ Live Weather (via NAT Gateway)</h2>
                        <p style="font-size: 42px; margin: 8px 0;">${w.temperature != null ? w.temperature + '°C' : '—'}</p>
                        <p style="font-size: 20px; margin: 4px 0;">${describeWeather(w.weathercode)}</p>
                        <p style="color: #475569;">💨 Wind: ${w.windspeed != null ? w.windspeed + ' km/h' : '—'} &nbsp;|&nbsp; 📍 ${data.location ? data.location.latitude + ', ' + data.location.longitude : ''}</p>
                    </div>

                    <div style="border: 2px solid #f59e0b; padding: 20px; border-radius: 8px; background-color: #fffbeb; max-width: 540px; text-align: left;">
                        <h2 style="color: #b45309; margin-top: 0;">🔔 Event Processing</h2>
                        <button id="publishButton" style="padding: 12px 20px; font-size: 16px; border:none; border-radius: 6px; background:#2563eb; color:#fff; cursor:pointer;">Publish Event</button>
                        <p id="publishMessage" style="margin: 16px 0 0; color:#334155;">Click to publish a demo event into the pub/sub topic.</p>
                        <p id="servedFromBadge" style="margin: 12px 0 4px; font-size: 13px; color:#475569;"></p>
                        <div id="eventStatus" style="margin-top: 4px; padding: 12px; background:#ffffff; border:1px solid #e2e8f0; border-radius: 6px; font-family: monospace;"></div>
                    </div>
                </div>

                <script>
                    async function refreshStatus() {
                        try {
                            const response = await fetch('/api/event-status');
                            const status = await response.json();
                            const servedFrom = status._servedFrom;
                            const payload = Object.fromEntries(Object.entries(status).filter(([k]) => k !== '_servedFrom'));
                            const zoneEl = document.getElementById('servedFromBadge');
                            if (servedFrom) {
                                zoneEl.innerHTML = '🌐 Refreshed from: <strong>' + (servedFrom.region || 'unknown') + '</strong> &nbsp;|&nbsp; Zone: <strong>' + (servedFrom.zone || 'unknown') + '</strong> &nbsp;|&nbsp; Instance: <code style="background:#e2e8f0;padding:2px 5px;">' + (servedFrom.instanceId || 'unknown') + '</code>';
                            }
                            document.getElementById('eventStatus').innerText = JSON.stringify(payload, null, 2);
                        } catch (error) {
                            document.getElementById('eventStatus').innerText = 'Unable to load event status: ' + error.message;
                        }
                    }

                    document.getElementById('publishButton').addEventListener('click', async () => {
                        document.getElementById('publishMessage').innerText = 'Publishing event...';
                        try {
                            const response = await fetch('/api/publish-event', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({}) });
                            const result = await response.json();
                            document.getElementById('publishMessage').innerText = result.message || 'Event published.';
                            refreshStatus();
                        } catch (error) {
                            document.getElementById('publishMessage').innerText = 'Publish failed: ' + error.message;
                        }
                    });

                    refreshStatus();
                    setInterval(refreshStatus, 5000);
                </script>
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