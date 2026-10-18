/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_AWS_ACCESS_KEY_ID: string
  readonly VITE_AWS_SECRET_ACCESS_KEY: string
  readonly VITE_AWS_REGION: string
  readonly VITE_AWS_ACCOUNT_ID: string
  readonly VITE_S3_ENDPOINT: string
  readonly VITE_IAM_ENDPOINT: string
  readonly VITE_IAM_PROXY_TARGET: string
  readonly VITE_S3_PROXY_TARGET: string
  readonly VITE_AWS_REGION_LABEL: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
