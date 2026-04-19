ARG NODE_VERSION=22.22.0

FROM node:${NODE_VERSION}-bookworm-slim

WORKDIR /app

ENV NODE_ENV=production

COPY package*.json ./
RUN npm ci --omit=dev

COPY server.js ./
COPY src/ ./src/

EXPOSE 4000

USER node

CMD ["node", "server.js"]
