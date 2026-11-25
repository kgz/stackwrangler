import {
  CreateClusterCommand,
  CreateServiceCommand,
  DescribeClustersCommand,
  DescribeServicesCommand,
  DescribeTaskDefinitionCommand,
  DescribeTasksCommand,
  ECSClient,
  ListClustersCommand,
  ListServicesCommand,
  ListTasksCommand,
  RunTaskCommand,
  StopTaskCommand,
  type Cluster,
  type Container,
  type Service,
  type Task,
  type TaskDefinition,
} from '@aws-sdk/client-ecs'
import { emuCreds } from './emu'

function client() {
  return new ECSClient(emuCreds())
}

export type LaunchTypeChoice = 'FARGATE' | 'EC2'

export type AwsLogsTarget = {
  containerName: string
  logGroupName: string
  logStreamName: string
  logStreamPrefix: string
}

export type NetworkConfigInput = {
  subnetIds: string[]
  securityGroupIds: string[]
  assignPublicIp?: 'ENABLED' | 'DISABLED'
}

function awsvpcNetworkConfiguration(net: NetworkConfigInput | undefined) {
  if (!net || net.subnetIds.length === 0) return undefined
  return {
    awsvpcConfiguration: {
      subnets: net.subnetIds,
      securityGroups: net.securityGroupIds,
      assignPublicIp: net.assignPublicIp ?? 'DISABLED',
    },
  }
}

export function parseCsvIds(raw: string): string[] {
  return raw
    .split(/[,\s]+/)
    .map((s) => s.trim())
    .filter(Boolean)
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

export async function describeTaskDefinition(
  taskDefinition: string,
): Promise<TaskDefinition | null> {
  const out = await client().send(
    new DescribeTaskDefinitionCommand({ taskDefinition }),
  )
  return out.taskDefinition ?? null
}

export async function runTask(opts: {
  cluster: string
  taskDefinition: string
  launchType?: LaunchTypeChoice
  network?: NetworkConfigInput
}): Promise<Task> {
  const out = await client().send(
    new RunTaskCommand({
      cluster: opts.cluster,
      taskDefinition: opts.taskDefinition,
      launchType: opts.launchType ?? 'FARGATE',
      networkConfiguration: awsvpcNetworkConfiguration(opts.network),
    }),
  )
  const task = out.tasks?.[0]
  if (!task) {
    const failure = out.failures?.[0]
    throw new Error(
      failure?.reason
        ? `RunTask failed: ${failure.reason}`
        : 'RunTask returned no task',
    )
  }
  return task
}

export async function createService(opts: {
  cluster: string
  serviceName: string
  taskDefinition: string
  desiredCount: number
  launchType?: LaunchTypeChoice
  network?: NetworkConfigInput
}): Promise<Service> {
  const out = await client().send(
    new CreateServiceCommand({
      cluster: opts.cluster,
      serviceName: opts.serviceName,
      taskDefinition: opts.taskDefinition,
      desiredCount: opts.desiredCount,
      launchType: opts.launchType ?? 'FARGATE',
      networkConfiguration: awsvpcNetworkConfiguration(opts.network),
    }),
  )
  const service = out.service
  if (!service) {
    throw new Error('CreateService returned no service')
  }
  return service
}

export async function stopTask(
  cluster: string,
  task: string,
  reason = 'Stopped from stackwrangler console',
): Promise<Task | null> {
  const out = await client().send(
    new StopTaskCommand({
      cluster,
      task,
      reason,
    }),
  )
  return out.task ?? null
}

export function awslogsTargetsForTask(
  taskDefinition: TaskDefinition | null | undefined,
  task: Task | null | undefined,
): AwsLogsTarget[] {
  if (!taskDefinition?.containerDefinitions?.length) return []
  const taskId = taskShortId(task?.taskArn)
  const out: AwsLogsTarget[] = []
  for (const cdef of taskDefinition.containerDefinitions) {
    const log = cdef.logConfiguration
    if (!log || log.logDriver !== 'awslogs') continue
    const options = log.options ?? {}
    const logGroupName = options['awslogs-group']?.trim()
    if (!logGroupName) continue
    const prefix = options['awslogs-stream-prefix']?.trim() || 'ecs'
    const containerName = cdef.name?.trim() || 'container'
    const logStreamName = `${prefix}/${containerName}/${taskId}`
    out.push({
      containerName,
      logGroupName,
      logStreamName,
      logStreamPrefix: prefix,
    })
  }
  return out
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

export type { Cluster, Container, Service, Task, TaskDefinition }
