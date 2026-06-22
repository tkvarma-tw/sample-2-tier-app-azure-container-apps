const express = require('express');
const axios = require('axios');
const app = express();

const PORT = process.env.PORT || 80;
const BACKEND_A_URL = process.env.BACKEND_A_URL;
const SERVICEBUS_CONNECTION_STRING = process.env.SERVICEBUS_CONNECTION_STRING;
const SERVICEBUS_TOPIC_NAME = process.env.SERVICEBUS_TOPIC_NAME || 'demo-events';

app.use(express.json());

app.post('/api/publish-event', async (req, res) => {
    if (!SERVICEBUS_CONNECTION_STRING) {
        return res.status(500).json({
            status: 'Error',
            message: 'Configuration error: SERVICEBUS_CONNECTION_STRING is missing.'
        });
    }

    try {
        const { ServiceBusClient } = require('@azure/service-bus');
        const client = new ServiceBusClient(SERVICEBUS_CONNECTION_STRING);
        const sender = client.createSender(SERVICEBUS_TOPIC_NAME);

        const eventPayload = {
            eventId: `evt-${Date.now()}`,
            source: 'aggregator-backend',
            createdAt: new Date().toISOString(),
            details: req.body.details || 'POC event from the aggregator backend'
        };

        await sender.sendMessages({
            body: eventPayload,
            contentType: 'application/json',
            subject: 'demo-event'
        });
        await sender.close();
        await client.close();

        res.json({
            status: 'Success',
            message: 'Event published to the topic.',
            event: eventPayload
        });
    } catch (error) {
        res.status(500).json({
            status: 'Error',
            message: 'Failed to publish event to Service Bus.',
            error: error.message
        });
    }
});

app.get('/api/event-status', async (req, res) => {
    if (!BACKEND_A_URL) {
        return res.status(500).json({
            status: 'Error',
            message: 'Configuration error: BACKEND_A_URL environment variable is missing.'
        });
    }

    try {
        const response = await axios.get(`${BACKEND_A_URL}/api/event-status`, { timeout: 5000 });
        res.json(response.data);
    } catch (error) {
        res.status(502).json({
            status: 'Upstream Error',
            message: `Failed to communicate with the existing backend service at ${BACKEND_A_URL}`,
            error: error.message
        });
    }
});

app.get('/api/aggregated-data', async (req, res) => {
    if (!BACKEND_A_URL) {
        return res.status(500).json({
            status: 'Error',
            message: 'Configuration error: BACKEND_A_URL environment variable is missing.'
        });
    }

    try {
        const response = await axios.get(`${BACKEND_A_URL}/api/data`, { timeout: 5000 });
        const upstream = response.data;

        res.json({
            status: 'Success',
            source: 'New Backend Service (B)',
            newData: 'This is extra data processed by Service B.',
            ...upstream,
            upstreamData: upstream
        });
    } catch (error) {
        res.status(502).json({
            status: 'Upstream Error',
            message: `Failed to communicate with the existing backend service at ${BACKEND_A_URL}`,
            error: error.message
        });
    }
});

app.listen(PORT, () => {
    console.log(`New Backend Service B listening on port ${PORT}`);
});
