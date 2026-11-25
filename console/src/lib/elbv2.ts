import {
  DescribeListenersCommand,
  DescribeLoadBalancersCommand,
  DescribeTargetGroupsCommand,
  DescribeTargetHealthCommand,
  ElasticLoadBalancingV2Client,
  type Listener,
  type LoadBalancer,
  type TargetGroup,
  type TargetHealthDescription,
} from '@aws-sdk/client-elastic-load-balancing-v2'
import { emuCreds } from './emu'

function client() {
  return new ElasticLoadBalancingV2Client(emuCreds())
}

export async function listLoadBalancers(): Promise<LoadBalancer[]> {
  const out = await client().send(new DescribeLoadBalancersCommand({}))
  return out.LoadBalancers ?? []
}

export async function describeLoadBalancer(
  arn: string,
): Promise<LoadBalancer | null> {
  const out = await client().send(
    new DescribeLoadBalancersCommand({ LoadBalancerArns: [arn] }),
  )
  return out.LoadBalancers?.[0] ?? null
}

export async function listListeners(loadBalancerArn: string): Promise<Listener[]> {
  const out = await client().send(
    new DescribeListenersCommand({ LoadBalancerArn: loadBalancerArn }),
  )
  return out.Listeners ?? []
}

export async function listTargetGroups(
  loadBalancerArn: string,
): Promise<TargetGroup[]> {
  const out = await client().send(
    new DescribeTargetGroupsCommand({ LoadBalancerArn: loadBalancerArn }),
  )
  return out.TargetGroups ?? []
}

export async function describeTargetHealth(
  targetGroupArn: string,
): Promise<TargetHealthDescription[]> {
  const out = await client().send(
    new DescribeTargetHealthCommand({ TargetGroupArn: targetGroupArn }),
  )
  return out.TargetHealthDescriptions ?? []
}

export type HealthByTargetGroup = ReadonlyArray<{
  targetGroupArn: string
  health: TargetHealthDescription[]
}>

export async function describeTargetHealthForGroups(
  groups: TargetGroup[],
): Promise<HealthByTargetGroup> {
  const rows: Array<{
    targetGroupArn: string
    health: TargetHealthDescription[]
  }> = []
  for (const tg of groups) {
    const targetGroupArn = tg.TargetGroupArn ?? ''
    if (!targetGroupArn) continue
    rows.push({
      targetGroupArn,
      health: await describeTargetHealth(targetGroupArn),
    })
  }
  return rows
}

export type {
  Listener,
  LoadBalancer,
  TargetGroup,
  TargetHealthDescription,
}
