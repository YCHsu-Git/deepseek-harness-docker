FROM node:22-bookworm

# native/ build artifacts and some pnpm deps need a C toolchain + python3;
# socat relays the app's 127.0.0.1-only listener to 0.0.0.0;
# curl/iproute2 are for diagnosing connectivity from inside the container
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git python3 make g++ ca-certificates socat curl iproute2 \
    && rm -rf /var/lib/apt/lists/*

# package.json pins its pnpm version; corepack fetches it on first use
RUN corepack enable

WORKDIR /app
COPY . .

RUN pnpm install --frozen-lockfile
RUN pnpm run build

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV DSH_HOME=/root/.dsh
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["web", "--no-open"]
