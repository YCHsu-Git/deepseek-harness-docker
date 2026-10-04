FROM node:22-bookworm

# native/ build artifacts and some pnpm deps need a C toolchain + python3;
# nginx proxies the app's 127.0.0.1-only listener to the container port;
# curl/iproute2 are for diagnosing connectivity from inside the container
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
    git python3 make g++ ca-certificates nginx curl iproute2 gnupg \
    && rm -rf /var/lib/apt/lists/*

# install the GitHub CLI (gh) from the official apt repository
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# package.json pins its pnpm version; corepack fetches it on first use
RUN corepack enable

WORKDIR /app
COPY . .

# dsh deliberately disables the settings RPC for non-loopback browser pages.
# This image terminates browser traffic through its authenticated Nginx proxy,
# so retain the existing host-backed settings document for remote users.
RUN grep -Fq "const persistence = ctx.remote.\$host.isLoopback ? 'host' : 'memory'" \
            packages/client/ui-settings/src/client/index.ts \
        && sed -i "s/const persistence = ctx.remote.\$host.isLoopback ? 'host' : 'memory'/const persistence = 'host'/" \
            packages/client/ui-settings/src/client/index.ts

RUN pnpm install --frozen-lockfile
RUN pnpm run build && test -s apps/cli/lib/bin.js

# apps/cli declares a "dsh" bin, but nothing installs it onto PATH; link it
# so `dsh` works from an interactive shell, matching entrypoint.sh's direct
# `node /app/apps/cli/lib/bin.js` invocation
RUN chmod +x apps/cli/lib/bin.js \
    && ln -s /app/apps/cli/lib/bin.js /usr/local/bin/dsh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY nginx.conf /etc/nginx/nginx.conf
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV DSH_HOME=/root/.dsh
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["web", "--no-open"]
