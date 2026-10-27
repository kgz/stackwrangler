import {
  AutoScalingClient,
  DescribeAutoScalingGroupsCommand,
  type AutoScalingGroup,
} from '@aws-sdk/client-auto-scaling'
import { emuCreds } from './emu'

function client() {
  return new AutoScalingClient(emuCreds())
}

export async function listAutoScalingGroups(): Promise<AutoScalingGroup[]> {
  const groups: AutoScalingGroup[] = []
  let nextToken: string | undefined
  do {
    const out = await client().send(
      new DescribeAutoScalingGroupsCommand({
        NextToken: nextToken,
        MaxRecords: 100,
      }),
    )
    groups.push(...(out.AutoScalingGroups ?? []))
    nextToken = out.NextToken
  } while (nextToken)
  return groups
}

export type { AutoScalingGroup }
