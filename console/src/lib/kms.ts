import {
  DescribeKeyCommand,
  KMSClient,
  ListAliasesCommand,
  ListKeysCommand,
} from '@aws-sdk/client-kms'
import { emuCreds } from './emu'

export type CustomerManagedKeyRow = {
  keyId: string
  alias: string
  status: string
  keySpec: string
  keyUsage: string
  creationDate: Date | undefined
}

function kmsClient(): KMSClient {
  return new KMSClient(emuCreds())
}

function statusLabel(keyState: string | undefined): string {
  if (!keyState) return '—'
  if (keyState === 'Enabled') return 'Enabled'
  if (keyState === 'Disabled') return 'Disabled'
  if (keyState === 'PendingDeletion') return 'Pending deletion'
  if (keyState === 'PendingImport') return 'Pending import'
  if (keyState === 'Unavailable') return 'Unavailable'
  return keyState
}

export async function listCustomerManagedKeys(): Promise<
  CustomerManagedKeyRow[]
> {
  const client = kmsClient()
  const keysOut = await client.send(new ListKeysCommand({ Limit: 100 }))
  const keyIds = (keysOut.Keys ?? [])
    .map((k) => k.KeyId)
    .filter((id): id is string => Boolean(id))

  const aliasByKey = new Map<string, string[]>()
  let marker: string | undefined
  do {
    const aliasesOut = await client.send(
      new ListAliasesCommand({ Limit: 100, Marker: marker }),
    )
    for (const a of aliasesOut.Aliases ?? []) {
      const target = a.TargetKeyId
      const name = a.AliasName
      if (!target || !name) continue
      if (name.startsWith('alias/aws/')) continue
      const list = aliasByKey.get(target) ?? []
      list.push(name)
      aliasByKey.set(target, list)
    }
    marker = aliasesOut.Truncated ? aliasesOut.NextMarker : undefined
  } while (marker)

  const rows: CustomerManagedKeyRow[] = []
  for (const keyId of keyIds) {
    const described = await client.send(
      new DescribeKeyCommand({ KeyId: keyId }),
    )
    const meta = described.KeyMetadata
    if (!meta || meta.KeyManager !== 'CUSTOMER') continue
    const aliases = aliasByKey.get(keyId) ?? aliasByKey.get(meta.KeyId ?? '')
    const alias =
      aliases && aliases.length > 0 ? aliases.slice().sort()[0]! : '—'
    rows.push({
      keyId: meta.KeyId ?? keyId,
      alias,
      status: statusLabel(meta.KeyState),
      keySpec: meta.KeySpec ?? '—',
      keyUsage: meta.KeyUsage ?? '—',
      creationDate: meta.CreationDate,
    })
  }

  rows.sort((a, b) => {
    const aa = a.alias === '—' ? a.keyId : a.alias
    const bb = b.alias === '—' ? b.keyId : b.alias
    return aa.localeCompare(bb)
  })
  return rows
}
