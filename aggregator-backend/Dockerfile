# 1. Use the official lightweight Node.js image
FROM node:20-alpine

# 2. Create and set the app directory inside the container
WORKDIR /app

RUN npm install express axios @azure/service-bus @azure/identity

# 4. Copy the rest of your application code
COPY server.js .

# 5. Expose the port your app runs on
EXPOSE 80

# 6. Command to start your app
CMD ["node", "server.js"]