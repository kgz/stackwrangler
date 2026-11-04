/**
 * Prefer STACKWRANGLER_*, else AWSBOX_*, else product default
 * (same precedence as bin/stackwrangler-env.sh / .env.example).
 */
export function swEnv(
  swName: string,
  abName: string,
  fallback = '',
): string {
  const sw = process.env[swName]
  if (sw !== undefined && sw !== '') return sw
  const ab = process.env[abName]
  if (ab !== undefined && ab !== '') return ab
  return fallback
}

export const e2eCreds = {
  accessKey: swEnv(
    'STACKWRANGLER_ACCESS_KEY',
    'AWSBOX_ACCESS_KEY',
    'stackwrangler',
  ),
  secretKey: swEnv(
    'STACKWRANGLER_SECRET_KEY',
    'AWSBOX_SECRET_KEY',
    'stackwranglerstackwrangler',
  ),
  region: swEnv('STACKWRANGLER_REGION', 'AWSBOX_REGION', 'us-east-1'),
  endpoint: swEnv(
    'STACKWRANGLER_ENDPOINT',
    'AWSBOX_ENDPOINT',
    'http://127.0.0.1:8333',
  ),
  iamEndpoint: swEnv(
    'STACKWRANGLER_IAM_ENDPOINT',
    'AWSBOX_IAM_ENDPOINT',
    'http://127.0.0.1:4566',
  ),
}
