import {
  DescribeInstancesCommand,
  DescribeSubnetsCommand,
  DescribeVpcsCommand,
  EC2Client,
  type Instance,
  type Reservation,
  type Subnet,
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

export async function listSubnets(vpcId: string): Promise<Subnet[]> {
  const out = await client().send(
    new DescribeSubnetsCommand({
      Filters: [{ Name: 'vpc-id', Values: [vpcId] }],
    }),
  )
  return out.Subnets ?? []
}

export function nameTag(
  tags: Array<{ Key?: string; Value?: string }> | undefined,
): string {
  return tags?.find((t) => t.Key === 'Name')?.Value ?? '—'
}

export type { Instance, Subnet, Vpc }
