ARG NODE_VERSION=22.22.0

FROM node:${NODE_VERSION}-bookworm-slim

WORKDIR /app

ENV NODE_ENV=production

# Baked-in version label — overridden at build time by blue-green-cutover.sh
# e.g. docker build --build-arg APP_VERSION=v2 -t api-server:v2 .
ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION}

COPY package*.json ./
RUN npm install --omit=dev

COPY src/ ./src/

EXPOSE 3000

USER node

CMD ["node", "src/index.js"]
