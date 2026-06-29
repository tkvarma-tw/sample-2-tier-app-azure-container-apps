const express = require('express');
const axios = require('axios');
const { ServiceBusClient } = require('@azure/service-bus');
const { ManagedIdentityCredential } = require('@azure/identity');
const sql = require('mssql');
const app = express();
const PORT = process.env.PORT || 80;

const LATITUDE = process.env.WEATHER_LATITUDE || '17.385';
const LONGITUDE = process.env.WEATHER_LONGITUDE || '78.4867';
const WEATHER_URL = `https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=${LATITUDE}&lon=${LONGITUDE}`;

const SERVICEBUS_NAMESPACE = process.env.SERVICEBUS_NAMESPACE;
const SERVICEBUS_TOPIC_NAME = process.env.SERVICEBUS_TOPIC_NAME || 'demo-events';
const SERVICEBUS_SUBSCRIPTION_NAME = process.env.SERVICEBUS_SUBSCRIPTION_NAME || 'demo-processor';

const SQL_SERVER = process.env.SQL_SERVER;
const SQL_DATABASE = process.env.SQL_DATABASE || 'demodb';

// Cached SQL connection pool — refreshed before the token expires (~1 h).
let sqlPool = null;
let sqlTokenExpiry = 0;

async function getSqlPool() {
    const now = Date.now();
    if (sqlPool && now < sqlTokenExpiry - 60_000) return sqlPool;

    if (sqlPool) { try { await sqlPool.close(); } catch (_) {} sqlPool = null; }

    const credential = new ManagedIdentityCredential();
    const tokenResponse = await credential.getToken('https://database.windows.net/.default');
    sqlTokenExpiry = tokenResponse.expiresOnTimestamp;

    sqlPool = await sql.connect({
        server: SQL_SERVER,
        database: SQL_DATABASE,
        authentication: {
            type: 'azure-active-directory-access-token',
            options: { token: tokenResponse.token }
        },
        options: { encrypt: true, trustServerCertificate: false, port: 1433 }
    });
    return sqlPool;
}

const processedEvents = [];

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

app.get('/api/event-status', (req, res) => {
    res.json({
        status: 'Success',
        latestProcessedEvent: processedEvents.length ? processedEvents[processedEvents.length - 1] : null,
        processedCount: processedEvents.length
    });
});

app.get('/api/sql-data', async (req, res) => {
    if (!SQL_SERVER) {
        return res.status(503).json({ status: 'Error', message: 'SQL_SERVER is not configured.' });
    }
    try {
        const pool = await getSqlPool();
        const result = await pool.request()
            .query('SELECT TOP 10 Id, PolicyNumber, PolicyHolder, PolicyType, Premium, StartDate, EndDate, Status FROM PolicyRecords ORDER BY Id');
        res.json({
            status: 'Success',
            source: 'Azure SQL Database (via Managed Identity)',
            server: SQL_SERVER,
            database: SQL_DATABASE,
            records: result.recordset
        });
    } catch (error) {
        console.error('SQL query failed:', error.message);
        res.status(502).json({ status: 'Error', message: 'Failed to query SQL database', error: error.message });
    }
});

function startServiceBusReceiver() {
    if (!SERVICEBUS_NAMESPACE) {
        console.error('SERVICEBUS_NAMESPACE is not configured. Event receiver will not start.');
        return;
    }

    console.log('Service Bus receiver: creating credential and client');
    const credential = new ManagedIdentityCredential();
    const fullyQualifiedNamespace = `${SERVICEBUS_NAMESPACE}.servicebus.windows.net`;
    console.log('Service Bus receiver: using namespace', fullyQualifiedNamespace);
    const client = new ServiceBusClient(fullyQualifiedNamespace, credential);
    const receiver = client.createReceiver(SERVICEBUS_TOPIC_NAME, SERVICEBUS_SUBSCRIPTION_NAME);

    receiver.subscribe({
        processMessage: async (message) => {
            console.log('Received event:', message.body);
            const event = {
                eventId: message.body?.eventId || `event-${Date.now()}`,
                receivedAt: new Date().toISOString(),
                status: 'Processed',
                payload: message.body
            };
            processedEvents.push(event);
        },
        processError: async (args) => {
            console.error('Service Bus processing error:', args.error);
            console.error('Service Bus processing error details:', {
                message: args.error?.message,
                code: args.error?.code,
                retryable: args.error?.retryable,
                info: args.error?.info,
                innerError: args.error?.innerError || args.error?.details
            });
        }
    }, { autoCompleteMessages: true, maxConcurrentCalls: 1 });
}

startServiceBusReceiver();

app.listen(PORT, () => console.log(`Backend listening on port ${PORT}`));