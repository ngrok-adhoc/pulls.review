# syntax=docker/dockerfile:1.7

# Builds the pulls.review site (packages/app) and serves it as a static SPA,
# like the Vercel deploy in vercel.json.

ARG NODE_VERSION=24

FROM node:${NODE_VERSION}-slim AS build

# The embed build stamps the userscript with `git rev-parse --short HEAD`.
RUN apt-get update \
  && apt-get install -y --no-install-recommends git ca-certificates \
  && rm -rf /var/lib/apt/lists/*

RUN npm install -g pnpm@12.9.1 \
  && pnpm config set store-dir /pnpm/store

WORKDIR /repo

# Install dependencies first, so that source changes keep this layer cached.
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml skills-npm.config.ts ./
COPY packages/actions/package.json packages/actions/
COPY packages/app/package.json packages/app/
COPY packages/cli/package.json packages/cli/
COPY packages/core/package.json packages/core/
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
  pnpm install --frozen-lockfile

COPY . .
RUN pnpm -F @pulls.review/app run build

FROM nginx:1.29-alpine AS runtime

COPY --from=build /repo/packages/app/dist /usr/share/nginx/html

# Send unknown paths to index.html, so that client-side routes load on refresh.
RUN cat > /etc/nginx/conf.d/default.conf <<'EOF'
server {
  listen 8080;
  root /usr/share/nginx/html;

  location / {
    try_files $uri $uri/ /index.html;
  }

  location = /index.html {
    add_header Cache-Control "no-cache";
  }

  location /assets/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
  }
}
EOF

EXPOSE 8080
