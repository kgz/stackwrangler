import {
  DescribeClustersCommand,
  DescribeServicesCommand,
  DescribeTasksCommand,
  ECSClient,
  ListClustersCommand,
  ListServicesCommand,
  ListTasksCommand,
  type Cluster,
  type Service,
  type Task,
} from '@aws-sdk/client-ecs'
import { emuCreds } from './emu'

function client() {
  return new ECSClient(emuCreds())
}

export async function listClusterArns(): Promise<string[]> {
  const out = await client().send(new ListClustersCommand({}))
  return out.clusterArns ?? []
}

export async function describeClusters(
  clusterArns: string[],
): Promise<Cluster[]> {
  if (clusterArns.length === 0) return []
  const out = await client().send(
    new DescribeClustersCommand({ clusters: clusterArns }),
  )
  return out.clusters ?? []
}

export async function listServiceArns(cluster: string): Promise<string[]> {
  const out = await client().send(
    new ListServicesCommand({ cluster }),
  )
  return out.serviceArns ?? []
}

export async function describeServices(
  cluster: string,
  serviceArns: string[],
): Promise<Service[]> {
  if (serviceArns.length === 0) return []
  const out = await client().send(
    new DescribeServicesCommand({ cluster, services: serviceArns }),
  )
  return out.services ?? []
}

export async function listTaskArns(cluster: string): Promise<string[]> {
  const out = await client().send(new ListTasksCommand({ cluster }))
  return out.taskArns ?? []
}

export async function describeTasks(
  cluster: string,
  taskArns: string[],
): Promise<Task[]> {
  if (taskArns.length === 0) return []
  const out = await client().send(
    new DescribeTasksCommand({ cluster, tasks: taskArns }),
  )
  return out.tasks ?? []
}

export type { Cluster, Service, Task }
