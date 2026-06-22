const express = require('express');
const axios = require('axios');
const app = express();

// Use a fallback port, but allow override via env variables
const PORT = process.env.PORT || 80;
// This must point to your *Existing* Backend Service URL
const BACKEND_A_URL = process.env.BACKEND_A_URL; 

app.use(express.json());

// Endpoint that the Frontend (or clients) can hit
app.get('/api/aggregated-data', async (req, res) => {
    if (!BACKEND_A_URL) {
        return res.status(500).json({
            status: "Error",
            message: "Configuration error: BACKEND_A_URL environment variable is missing."
        });
    }

    try {
        // Calling the existing backend microservice
        const response = await axios.get(`${BACKEND_A_URL}/api/data`, { timeout: 5000 });
        const upstream = response.data;
        
        // Preserve the original backend payload while also adding service B metadata.
        res.json({
            status: "Success",
            source: "New Backend Service (B)",
            newData: "This is extra data processed by Service B.",
            ...upstream,
            upstreamData: upstream
        });

    } catch (error) {
        res.status(502).json({
            status: "Upstream Error",
            message: `Failed to communicate with the existing backend service at ${BACKEND_A_URL}`,
            error: error.message
        });
    }
});

app.listen(PORT, () => {
    console.log(`New Backend Service B listening on port ${PORT}`);
});