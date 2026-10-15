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

# /gh-api/ forwards to the GitHub API. The ngrok traffic policy
# (deploy/traffic-policy.yml) gates the site with GitHub OAuth and adds the
# viewer's GitHub token in X-GitHub-OAuth-Token. nginx sends that token first.
# When GitHub rejects it with 401, nginx sends the request again with the token
# from the browser (set in Settings), or with no token.
# The nginx entrypoint replaces ${LLM_UPSTREAM} and writes conf.d/default.conf.
# Send unknown paths to index.html, so that client-side routes load on refresh.
RUN mkdir -p /etc/nginx/templates && cat > /etc/nginx/templates/default.conf.template <<'EOF'
map $http_x_github_oauth_token $gh_api_authorization {
  ""      $http_authorization;
  default "Bearer $http_x_github_oauth_token";
}

server {
  listen 8080;
  root /usr/share/nginx/html;

  proxy_ssl_server_name on;
  proxy_ssl_verify on;
  proxy_ssl_trusted_certificate /etc/ssl/certs/ca-certificates.crt;
  proxy_ssl_verify_depth 3;
  proxy_http_version 1.1;

  location /llm/ {
    proxy_pass ${LLM_UPSTREAM}/;
    # Do not send the GitHub token to the LLM gateway.
    proxy_set_header X-GitHub-OAuth-Token "";
    # Stream the model output to the browser as it arrives.
    proxy_buffering off;
    proxy_read_timeout 300s;
    # Large diffs make large prompts.
    client_max_body_size 20m;
  }

  location /gh-api/ {
    # The app sends this header on every call. A cross-site form cannot, so
    # this stops CSRF that rides on the OAuth session cookie.
    if ($http_x_github_api_version = "") {
      return 403;
    }
    proxy_pass https://api.github.com/;
    proxy_set_header Authorization $gh_api_authorization;
    proxy_set_header X-GitHub-OAuth-Token "";
    # Do not send the ngrok session cookie to GitHub.
    proxy_set_header Cookie "";
    proxy_intercept_errors on;
    error_page 401 = @gh_api_browser_token;
  }

  # The OAuth token is not valid: send the request again with the browser token.
  # A named location cannot set a URI in proxy_pass, so rewrite removes /gh-api.
  location @gh_api_browser_token {
    rewrite ^/gh-api/(.*)$ /$1 break;
    proxy_pass https://api.github.com;
    proxy_set_header Authorization $http_authorization;
    proxy_set_header X-GitHub-OAuth-Token "";
    proxy_set_header Cookie "";
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
