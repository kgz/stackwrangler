function resolveIamEndpoint(): string {
  const raw = import.meta.env.VITE_IAM_ENDPOINT || '/aws-iam'
  if (/^https?:\/\//i.test(raw)) {
    return raw
  }
  const path = raw.startsWith('/') ? raw : `/${raw}`
  if (typeof window !== 'undefined' && window.location?.origin) {
    return `${window.location.origin}${path}`
  }
  return `http://127.0.0.1:3000${path}`
}

export const config = {
  accessKeyId: import.meta.env.VITE_AWS_ACCESS_KEY_ID || 'awsbox',
  secretAccessKey: import.meta.env.VITE_AWS_SECRET_ACCESS_KEY || 'awsboxawsbox',
  region: import.meta.env.VITE_AWS_REGION || 'us-east-1',
  accountId: import.meta.env.VITE_AWS_ACCOUNT_ID || '000000000000',
  /** SeaweedFS S3 API (CORS enabled) */
  endpoint: import.meta.env.VITE_S3_ENDPOINT || 'http://127.0.0.1:8333',
  /** Browser uses Vite `/aws-iam` proxy → LocalEmu (avoids CORS) */
  iamEndpoint: resolveIamEndpoint(),
  regionLabel: import.meta.env.VITE_AWS_REGION_LABEL || 'US East (N. Virginia)',
}
