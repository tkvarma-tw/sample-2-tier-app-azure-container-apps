FROM node:18-alpine
WORKDIR /app
RUN npm install express axios @azure/service-bus
COPY server.js .
EXPOSE 80
CMD ["node", "server.js"]