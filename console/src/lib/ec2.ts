import {
  DescribeInstancesCommand,
  DescribeVpcsCommand,
  EC2Client,
  type Instance,
  type Reservation,
  type Vpc,
} from '@aws-sdk/client-ec2'
import { emuCreds } from './emu'

function client() {
  return new EC2Client(emuCreds())
}

export async function listInstances(): Promise<Instance[]> {
  const out = await client().send(new DescribeInstancesCommand({}))
  const reservations: Reservation[] = out.Reservations ?? []
  const instances: Instance[] = []
  for (const r of reservations) {
    for (const i of r.Instances ?? []) {
      instances.push(i)
    }
  }
  return instances
}

export async function listVpcs(): Promise<Vpc[]> {
  const out = await client().send(new DescribeVpcsCommand({}))
  return out.Vpcs ?? []
}

export async function describeVpc(vpcId: string): Promise<Vpc | null> {
  const out = await client().send(new DescribeVpcsCommand({ VpcIds: [vpcId] }))
  return out.Vpcs?.[0] ?? null
}

export type { Instance, Vpc }
