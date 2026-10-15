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
# The app sends GitHub API calls to the /gh-api/ proxy below, not to api.github.com.
RUN VITE_GITHUB_API_BASE=/gh-api pnpm -F @pulls.review/app run build

FROM nginx:1.29-alpine AS runtime

COPY --from=build /repo/packages/app/dist /usr/share/nginx/html

# The LLM gateway sends no CORS headers, so the browser cannot call it directly.
# /llm/ forwards to the gateway from the same origin. In the app, set the
# OpenAI-compatible base URL to https://<this host>/llm/v1.
ENV LLM_UPSTREAM=https://gateway.ngrok.ai

# /gh-api/ forwards to the GitHub API and adds GITHUB_TOKEN when the browser
# sends no token. Viewers then need no token of their own. Set GITHUB_TOKEN as a
# runtime secret. Do not set it in this file, because the image keeps it.
# The ngrok OAuth policy is the only gate on this token: keep it read-only.
ENV GITHUB_TOKEN=""

# The nginx entrypoint replaces ${LLM_UPSTREAM} and ${GITHUB_TOKEN} and writes
# conf.d/default.conf. Send unknown paths to index.html, so that client-side
# routes load on refresh.
RUN mkdir -p /etc/nginx/templates && cat > /etc/nginx/templates/default.conf.template <<'EOF'
# No Authorization header when GITHUB_TOKEN is empty: nginx does not send a
# header with an empty value, so requests stay anonymous.
map "${GITHUB_TOKEN}" $gh_api_server_authorization {
  ""      "";
  default "Bearer ${GITHUB_TOKEN}";
}

# A token from the browser (set in Settings) wins over the server token.
map $http_authorization $gh_api_authorization {
  ""      $gh_api_server_authorization;
  default $http_authorization;
}

# With the server token, allow only GET, HEAD, and POST to /graphql. GraphQL
# mutations also use POST /graphql, so this does not make the proxy read-only.
# Only a read-only GITHUB_TOKEN does that. A browser token can do all that it
# permits.
map "$http_authorization|$request_method|$uri" $gh_api_blocked {
  default                        0;
  "~^\|(GET|HEAD)\|"             0;
  "~^\|POST\|/gh-api/graphql$"   0;
  "~^\|"                         1;
}

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

  location /gh-api/ {
    # The app sends this header on every call. A cross-site form cannot, so
    # this stops CSRF that rides on the SSO cookie.
    if ($http_x_github_api_version = "") {
      return 403;
    }
    if ($gh_api_blocked) {
      return 403;
    }
    proxy_pass https://api.github.com/;
    proxy_set_header Authorization $gh_api_authorization;
    # Do not send the ngrok session cookie to GitHub.
    proxy_set_header Cookie "";
    proxy_ssl_server_name on;
    proxy_ssl_verify on;
    proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
    proxy_ssl_verify_depth 3;
    proxy_http_version 1.1;
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
RUN envsubst '${LLM_UPSTREAM} ${GITHUB_TOKEN}' < /etc/nginx/templates/default.conf.template > /etc/nginx/conf.d/default.conf \
  && nginx -t

EXPOSE 8080
