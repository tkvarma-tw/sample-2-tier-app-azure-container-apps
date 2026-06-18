const express = require('express');
const axios = require('axios');
const app = express();
const PORT = process.env.PORT || 80;
const BACKEND_URL = process.env.BACKEND_URL;

app.get('/', async (req, res) => {
    try {
        // Fetch data from the Azure Container App backend
        const response = await axios.get(`${BACKEND_URL}/api/data`);

        res.send(`
            <html>
            <body style="font-family: Arial, sans-serif; margin: 40px; text-align: center;">
                <h1 style="color: #0078d4;">Azure End-to-End Connectivity Test</h1>
                <div style="border: 2px solid #22c55e; padding: 20px; border-radius: 8px; display: inline-block; background-color: #f0fdf4;">
                    <h2 style="color: #15803d; margin-top: 0;">✅ Connection Successful!</h2>
                    <p><strong>Frontend fetched data from:</strong> <code style="background: #e2e8f0; padding: 2px 6px;">${BACKEND_URL}</code></p>
                    <p><strong>Backend Response:</strong></p>
                    <pre style="text-align: left; background: #27272a; color: #f4f4f5; padding: 15px; border-radius: 4px;">${JSON.stringify(response.data, null, 2)}</pre>
                </div>
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