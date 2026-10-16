# syntax=docker/dockerfile:1

FROM node:24.16.0-alpine3.22 AS build

WORKDIR /app

COPY package.json package-lock.json ./
COPY apps/api/package.json ./apps/api/package.json
COPY apps/worker/package.json ./apps/worker/package.json
COPY packages/shared/package.json ./packages/shared/package.json

RUN npm ci

COPY apps/api ./apps/api
COPY apps/worker ./apps/worker
COPY packages/shared ./packages/shared

RUN npm run build -w @beacon/api


FROM node:24.16.0-alpine3.22 AS runtime

ENV NODE_ENV=production

WORKDIR /app

COPY package.json package-lock.json ./
COPY apps/api/package.json ./apps/api/package.json
COPY apps/worker/package.json ./apps/worker/package.json
COPY packages/shared/package.json ./packages/shared/package.json

RUN npm ci --omit=dev

COPY --from=build --chown=node:node /app/apps/api/dist ./apps/api/dist
COPY --from=build --chown=node:node /app/apps/api/migrations ./apps/api/migrations

USER node

EXPOSE 3000

CMD ["node", "apps/api/dist/index.js"]
