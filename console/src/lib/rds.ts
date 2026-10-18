import {
  DeleteDBInstanceCommand,
  DescribeDBInstancesCommand,
  RDSClient,
  type DBInstance,
} from '@aws-sdk/client-rds'
import { emuCreds } from './emu'

function client() {
  return new RDSClient(emuCreds())
}

export async function listDbInstances(): Promise<DBInstance[]> {
  const out = await client().send(new DescribeDBInstancesCommand({}))
  return out.DBInstances ?? []
}

export async function describeDbInstance(
  id: string,
): Promise<DBInstance | null> {
  const out = await client().send(
    new DescribeDBInstancesCommand({ DBInstanceIdentifier: id }),
  )
  return out.DBInstances?.[0] ?? null
}

export async function deleteDbInstance(id: string): Promise<void> {
  await client().send(
    new DeleteDBInstanceCommand({
      DBInstanceIdentifier: id,
      SkipFinalSnapshot: true,
    }),
  )
}

export type { DBInstance }
