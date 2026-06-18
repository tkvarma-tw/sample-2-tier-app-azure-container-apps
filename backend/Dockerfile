FROM node:18-alpine
WORKDIR /app
RUN npm install express
COPY server.js .
EXPOSE 80
CMD ["node", "server.js"]