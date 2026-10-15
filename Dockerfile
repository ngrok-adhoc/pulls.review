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
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY packages/actions/package.json packages/actions/
COPY packages/app/package.json packages/app/
COPY packages/cli/package.json packages/cli/
COPY packages/core/package.json packages/core/
# Skip the root `prepare` script (skills-npm). It downloads agent skills from
# GitHub, which the image does not need and which can fail on shared runners.
# `pnpm rebuild` then runs the dependency build scripts that `allowBuilds` permits.
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
  pnpm install --frozen-lockfile --ignore-scripts \
  && pnpm rebuild

COPY . .
RUN pnpm -F @pulls.review/app run build

FROM nginx:1.29-alpine AS runtime

COPY --from=build /repo/packages/app/dist /usr/share/nginx/html

# The LLM gateway sends no CORS headers, so the browser cannot call it directly.
# /llm/ forwards to the gateway from the same origin. In the app, set the
# OpenAI-compatible base URL to https://<this host>/llm/v1.
ENV LLM_UPSTREAM=https://gateway.ngrok.ai

# The nginx entrypoint replaces ${LLM_UPSTREAM} and writes conf.d/default.conf.
# Send unknown paths to index.html, so that client-side routes load on refresh.
RUN mkdir -p /etc/nginx/templates && cat > /etc/nginx/templates/default.conf.template <<'EOF'
server {
  listen 8080;
  root /usr/share/nginx/html;

  location /llm/ {
    proxy_pass ${LLM_UPSTREAM}/;
    proxy_ssl_server_name on;
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 3;
    proxy_http_version 1.1;
    # Stream the model output to the browser as it arrives.
    proxy_buffering off;
    proxy_read_timeout 300s;
    # Large diffs make large prompts.
    client_max_body_size 20m;
  }

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

# Render and test the config now, so that a bad config fails the build and
# does not stop the container at start.
RUN envsubst '${LLM_UPSTREAM}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf \
  && nginx -t

EXPOSE 8080
