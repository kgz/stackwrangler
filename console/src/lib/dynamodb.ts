import {
  DescribeTableCommand,
  DynamoDBClient,
  ListTablesCommand,
} from '@aws-sdk/client-dynamodb'
import { emuCreds } from './emu'

export type DynamoDBTableRow = {
  name: string
  status: string
  partitionKey: string
  sortKey: string
  indexes: string
  capacityMode: string
}

function dynamodbClient(): DynamoDBClient {
  return new DynamoDBClient(emuCreds())
}

function attrLabel(
  name: string | undefined,
  type: string | undefined,
): string {
  if (!name) return '—'
  if (!type) return name
  return `${name} (${type})`
}

function keySchemaLabels(
  keySchema: { AttributeName?: string; KeyType?: string }[] | undefined,
  attrTypes: Map<string, string>,
): { partitionKey: string; sortKey: string } {
  let partitionKey = '—'
  let sortKey = '—'
  for (const k of keySchema ?? []) {
    const name = k.AttributeName
    if (!name) continue
    const label = attrLabel(name, attrTypes.get(name))
    if (k.KeyType === 'HASH') partitionKey = label
    if (k.KeyType === 'RANGE') sortKey = label
  }
  return { partitionKey, sortKey }
}

function indexesLabel(
  gsiCount: number,
  lsiCount: number,
  gsiNames: string[],
): string {
  const total = gsiCount + lsiCount
  if (total === 0) return '0'
  if (gsiNames.length === 1 && lsiCount === 0) return gsiNames[0] ?? '1'
  return String(total)
}

function capacityLabel(mode: string | undefined): string {
  if (mode === 'PAY_PER_REQUEST') return 'On-demand'
  if (mode === 'PROVISIONED') return 'Provisioned'
  if (!mode) return 'Provisioned'
  return mode
}

function statusLabel(status: string | undefined): string {
  if (!status) return '—'
  if (status === 'ACTIVE') return 'Active'
  if (status === 'CREATING') return 'Creating'
  if (status === 'UPDATING') return 'Updating'
  if (status === 'DELETING') return 'Deleting'
  return status
}

async function listTableNames(): Promise<string[]> {
  const names: string[] = []
  let exclusiveStartTableName: string | undefined
  for (;;) {
    const out = await dynamodbClient().send(
      new ListTablesCommand({
        Limit: 100,
        ExclusiveStartTableName: exclusiveStartTableName,
      }),
    )
    for (const name of out.TableNames ?? []) {
      if (name) names.push(name)
    }
    exclusiveStartTableName = out.LastEvaluatedTableName
    if (!exclusiveStartTableName) break
  }
  return names
}

export async function listTables(): Promise<DynamoDBTableRow[]> {
  const names = await listTableNames()
  const rows = await Promise.all(
    names.map(async (name) => {
      try {
        const out = await dynamodbClient().send(
          new DescribeTableCommand({ TableName: name }),
        )
        const table = out.Table
        const attrTypes = new Map<string, string>()
        for (const a of table?.AttributeDefinitions ?? []) {
          if (a.AttributeName && a.AttributeType) {
            attrTypes.set(a.AttributeName, a.AttributeType)
          }
        }
        const { partitionKey, sortKey } = keySchemaLabels(
          table?.KeySchema,
          attrTypes,
        )
        const gsis = table?.GlobalSecondaryIndexes ?? []
        const lsis = table?.LocalSecondaryIndexes ?? []
        const gsiNames = gsis
          .map((g) => g.IndexName)
          .filter((n): n is string => Boolean(n))
        return {
          name: table?.TableName ?? name,
          status: statusLabel(table?.TableStatus),
          partitionKey,
          sortKey,
          indexes: indexesLabel(gsis.length, lsis.length, gsiNames),
          capacityMode: capacityLabel(table?.BillingModeSummary?.BillingMode),
        } satisfies DynamoDBTableRow
      } catch {
        return {
          name,
          status: '—',
          partitionKey: '—',
          sortKey: '—',
          indexes: '—',
          capacityMode: '—',
        } satisfies DynamoDBTableRow
      }
    }),
  )
  return rows.sort((a, b) => a.name.localeCompare(b.name))
}
