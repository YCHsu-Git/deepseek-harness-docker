FROM node:20-bookworm

# native/ build artifacts and some pnpm deps need a C toolchain + python3
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       git python3 make g++ ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# package.json pins its pnpm version; corepack fetches it on first use
RUN corepack enable

WORKDIR /app
COPY . .

RUN pnpm install --frozen-lockfile
RUN pnpm run build

# dsh only supports binding to 127.0.0.1; run the container with --network host
ENV DSH_HOME=/root/.dsh
EXPOSE 3080

ENTRYPOINT ["pnpm", "dsh"]
CMD ["web", "--no-open"]
