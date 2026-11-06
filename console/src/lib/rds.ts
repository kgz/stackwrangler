import {
  CreateDBInstanceCommand,
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

export type CreateDbInstanceInput = {
  identifier: string
  engine: 'postgres' | 'mysql'
  engineVersion: string
  instanceClass: string
  allocatedStorage: number
  masterUsername: string
  masterUserPassword: string
  dbName?: string
}

export async function createDbInstance(
  input: CreateDbInstanceInput,
): Promise<void> {
  await client().send(
    new CreateDBInstanceCommand({
      DBInstanceIdentifier: input.identifier,
      Engine: input.engine,
      EngineVersion: input.engineVersion,
      DBInstanceClass: input.instanceClass,
      AllocatedStorage: input.allocatedStorage,
      MasterUsername: input.masterUsername,
      MasterUserPassword: input.masterUserPassword,
      DBName: input.dbName || undefined,
    }),
  )
}

export type { DBInstance }
