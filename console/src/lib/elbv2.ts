import {
  DescribeLoadBalancersCommand,
  DescribeTargetGroupsCommand,
  DescribeTargetHealthCommand,
  ElasticLoadBalancingV2Client,
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

export async function listTargetGroups(): Promise<TargetGroup[]> {
  const out = await client().send(new DescribeTargetGroupsCommand({}))
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

export type { LoadBalancer, TargetGroup, TargetHealthDescription }
