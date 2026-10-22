import {
  DescribeLoadBalancersCommand,
  ElasticLoadBalancingV2Client,
  type LoadBalancer,
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

export type { LoadBalancer }
