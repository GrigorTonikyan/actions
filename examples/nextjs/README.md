# Next.js 16+ Production Container & CI/CD Reference Template

Canonical reference configuration eliminating ZFS + `overlay2` (`metacopy: false`) build bottlenecks, TLS bypasses, and redundant CI checks.

## Files Included

- [`Dockerfile`](./Dockerfile): Single unified `builder` stage (`# syntax=docker/dockerfile:1`) with BuildKit cache mounts for Bun (`/root/.bun/install/cache`) and Next.js (`/app/.next/cache`), optional internal CA secret mount (`--mount=type=secret,id=internal_ca,required=false`), `COPY --link`, and non-root `nextjs:nodejs` runtime.
- [`.dockerignore`](./.dockerignore): Excludes VCS, CI, docs, tests, scripts, local caches, and `.env*` secrets from the Docker build context.
- [`next.config.ts`](./next.config.ts): Configures `output: "standalone"` and `experimental.turbopackFileSystemCacheForBuild: true`.
- [`.gitea/workflows/ci.yaml`](./.gitea/workflows/ci.yaml): PR validation workflow using `pull_request` + `workflow_dispatch`, shallow `fetch-depth: 1`, `self:gt-dev/actions/setup-toolchains@v1` (with `nextjs-cache: "true"`), `playwright-runner:v1.65.0`, and `self:gt-dev/actions/docker-build-push@v1`.
- [`.gitea/workflows/deploy.yaml`](./.gitea/workflows/deploy.yaml): Main branch CD workflow pushing immutable version/SHA tags via `self:gt-dev/actions/docker-build-push@v1`.

## Using Pre-Baked `bun-node-alpine` & `node-alpine-runner` Images

Once `.gitea/workflows/publish-alpine-images.yaml` publishes `bun-node-alpine` and `node-alpine-runner` to your Gitea container registry, replace the `builder` and `runner` base stages in `Dockerfile` with their published `@sha256:` manifest digests to eliminate `apk add` and Bun extraction entirely:

```dockerfile
FROM git.gt-web-dev.com/gt-dev/bun-node-alpine:26-1.4@sha256:<PUBLISHED_DIGEST> AS builder
...
FROM git.gt-web-dev.com/gt-dev/node-alpine-runner:26@sha256:<PUBLISHED_DIGEST> AS runner
```
