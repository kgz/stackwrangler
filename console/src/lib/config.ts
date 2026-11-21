function resolveLocalEndpoint(raw: string): string {
  if (/^https?:\/\//i.test(raw)) {
    return raw
  }
  const path = raw.startsWith('/') ? raw : `/${raw}`
  if (typeof window !== 'undefined' && window.location?.origin) {
    return `${window.location.origin}${path}`
  }
  return `http://127.0.0.1:3000${path}`
}

function resolveIamEndpoint(): string {
  return resolveLocalEndpoint(import.meta.env.VITE_IAM_ENDPOINT || '/aws-iam')
}

function resolveS3Endpoint(): string {
  // Org-path brain = LocalEmu via same-origin proxy (default /aws-iam).
  return resolveLocalEndpoint(
    import.meta.env.VITE_S3_ENDPOINT || import.meta.env.VITE_IAM_ENDPOINT || '/aws-iam',
  )
}

export const config = {
  accessKeyId: import.meta.env.VITE_AWS_ACCESS_KEY_ID || 'stackwrangler',
  secretAccessKey: import.meta.env.VITE_AWS_SECRET_ACCESS_KEY || 'stackwranglerstackwrangler',
  region: import.meta.env.VITE_AWS_REGION || 'us-east-1',
  accountId: import.meta.env.VITE_AWS_ACCOUNT_ID || '000000000000',
  /** Org-path S3 = LocalEmu (same store as profile local / IaC) (#162). */
  endpoint: resolveS3Endpoint(),
  /** Browser uses Vite `/aws-iam` proxy → LocalEmu (avoids CORS) */
  iamEndpoint: resolveIamEndpoint(),
  regionLabel: import.meta.env.VITE_AWS_REGION_LABEL || 'US East (N. Virginia)',
}
