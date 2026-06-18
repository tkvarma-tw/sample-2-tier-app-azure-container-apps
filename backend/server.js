const express = require('express');
const app = express();
const PORT = process.env.PORT || 80;

// A simple endpoint the frontend can hit
app.get('/api/data', (req, res) => {
    res.json({
        status: "Success",
        message: "Hello from the Container App Backend!",
        timestamp: new Date()
    });
});

app.listen(PORT, () => console.log(`Backend listening on port ${PORT}`));