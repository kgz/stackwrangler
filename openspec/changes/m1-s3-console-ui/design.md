## Context

SeaweedFS on `:8333`, profile `local`. Build product console (not MinIO/Seaweed UI). Match AWS dark S3 buckets page from the ref screenshot.

## Goals / Non-Goals

**Goals:**

- Open `http://127.0.0.1:3000` → AWS-feel shell → S3 → General purpose buckets from `ListBuckets`
- Create bucket, open bucket, upload/download/delete objects
- Surface S3 errors (`AccessDenied`, `NoSuchBucket`, …) in the UI

**Non-Goals:**

- Auth login screen (keys from Vite env / `.env`)
- Full AWS service catalog

## Decisions

1. **Vite + React + TypeScript** — fast local DX; `@aws-sdk/client-s3` with `forcePathStyle` + custom endpoint.
2. **Keys in `console/.env`** copied from root `.env` by `awsbox up` (or Vite `envDir: '..'`).
3. **Visual language** — copy AWS dark tokens from ref (charcoal header, orange primary, blue links/active). Not a new brand; intentional AWS mimic.
4. **General purpose buckets** is the live tab; Directory buckets empty stub (SeaweedFS has no directory buckets).
5. **CORS** — SeaweedFS `weed mini` already returns `Access-Control-Allow-Origin: *`. Browser SDK talks to `http://127.0.0.1:8333` directly (Vite path-proxy breaks SigV4).

## Risks / Trade-offs

- [Browser CORS to :8333] → Vite proxy in dev; document for prod static host
- [AWS UI churn] → ref screenshot pinned in `design/stackwrangler-console/refs/`
- [SDK checksum middleware vs SeaweedFS] → disable flexible checksums if PutObject fails
