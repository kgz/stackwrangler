import {
  DescribeInstancesCommand,
  EC2Client,
  type Instance,
  type Reservation,
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

export type { Instance }
