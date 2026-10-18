import { config } from './config'

/** Shared credentials + LocalEmu endpoint (via Vite /aws-iam proxy in browser). */
export function emuCreds() {
  return {
    region: config.region,
    endpoint: config.iamEndpoint,
    credentials: {
      accessKeyId: config.accessKeyId,
      secretAccessKey: config.secretAccessKey,
    },
  }
}
