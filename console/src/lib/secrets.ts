import {
  CreateSecretCommand,
  DescribeSecretCommand,
  GetSecretValueCommand,
  ListSecretsCommand,
  ListSecretVersionIdsCommand,
  SecretsManagerClient,
  type SecretListEntry,
  type SecretVersionsListEntry,
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

export async function createSecret(input: {
  name: string
  secretString: string
  description?: string
}): Promise<{ arn: string; name: string }> {
  const out = await secretsClient().send(
    new CreateSecretCommand({
      Name: input.name,
      SecretString: input.secretString,
      Description: input.description,
    }),
  )
  return {
    arn: out.ARN ?? '',
    name: out.Name ?? input.name,
  }
}

export type SecretDetail = {
  name: string
  arn: string
  description: string
  kmsKeyId: string
  createdDate: Date | undefined
  lastAccessedDate: Date | undefined
  lastChangedDate: Date | undefined
  deletedDate: Date | undefined
}

export async function describeSecret(secretId: string): Promise<SecretDetail> {
  const out = await secretsClient().send(
    new DescribeSecretCommand({ SecretId: secretId }),
  )
  return {
    name: out.Name ?? secretId,
    arn: out.ARN ?? '',
    description: out.Description ?? '',
    kmsKeyId: out.KmsKeyId ?? 'aws/secretsmanager',
    createdDate: out.CreatedDate,
    lastAccessedDate: out.LastAccessedDate,
    lastChangedDate: out.LastChangedDate,
    deletedDate: out.DeletedDate,
  }
}

export async function listSecretVersions(
  secretId: string,
): Promise<SecretVersionsListEntry[]> {
  const out = await secretsClient().send(
    new ListSecretVersionIdsCommand({
      SecretId: secretId,
      IncludeDeprecated: true,
      MaxResults: 100,
    }),
  )
  return out.Versions ?? []
}

export async function getSecretString(secretId: string): Promise<string> {
  const out = await secretsClient().send(
    new GetSecretValueCommand({ SecretId: secretId }),
  )
  if (out.SecretString != null) return out.SecretString
  if (out.SecretBinary) {
    return '[binary secret — plaintext view not available]'
  }
  return ''
}

export type { SecretListEntry, SecretVersionsListEntry }
