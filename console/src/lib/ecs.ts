import {
  CreateClusterCommand,
  DescribeClustersCommand,
  DescribeServicesCommand,
  DescribeTasksCommand,
  ECSClient,
  ListClustersCommand,
  ListServicesCommand,
  ListTasksCommand,
  type Cluster,
  type Container,
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

export async function createCluster(clusterName: string): Promise<Cluster> {
  const out = await client().send(
    new CreateClusterCommand({ clusterName }),
  )
  const cluster = out.cluster
  if (!cluster) {
    throw new Error('CreateCluster returned no cluster')
  }
  return cluster
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

export async function describeTask(
  cluster: string,
  taskArn: string,
): Promise<Task | null> {
  const tasks = await describeTasks(cluster, [taskArn])
  return tasks[0] ?? null
}

export function taskShortId(taskArn: string | undefined): string {
  if (!taskArn) return '—'
  return taskArn.split('/').pop() || taskArn
}

export function taskDefinitionFamily(
  taskDefinitionArn: string | undefined,
): string {
  if (!taskDefinitionArn) return '—'
  const part = taskDefinitionArn.split('/').pop()
  return part || taskDefinitionArn
}

export function formatTaskTime(value: Date | string | undefined): string {
  if (!value) return '—'
  const d = value instanceof Date ? value : new Date(value)
  if (Number.isNaN(d.getTime())) return '—'
  return d.toISOString().replace('T', ' ').replace(/\.\d{3}Z$/, ' UTC')
}

export function containerPrivateIp(
  container: Container | undefined,
): string {
  const eni = container?.networkInterfaces?.[0]
  return eni?.privateIpv4Address ?? '—'
}

export type { Cluster, Container, Service, Task }
