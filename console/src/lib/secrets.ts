import {
  ListSecretsCommand,
  SecretsManagerClient,
  type SecretListEntry,
} from '@aws-sdk/client-secrets-manager'
import { emuCreds } from './emu'

function secretsClient(): SecretsManagerClient {
  return new SecretsManagerClient(emuCreds())
}

export async function listSecrets(): Promise<SecretListEntry[]> {
  const out = await secretsClient().send(
    new ListSecretsCommand({ MaxResults: 100 }),
  )
  return out.SecretList ?? []
}

export type { SecretListEntry }
