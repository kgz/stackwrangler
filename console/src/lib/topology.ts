import { listBuckets } from './s3'
import {
  listInstances,
  listInternetGateways,
  listNatGateways,
  listRouteTables,
  listSubnets,
  listVpcs,
  nameTag,
  type Instance,
  type InternetGateway,
  type NatGateway,
  type RouteTable,
  type Subnet,
  type Vpc,
} from './ec2'
import {
  describeClusters,
  describeServices,
  describeTaskDefinition,
  listClusterArns,
  listServiceArns,
  type Cluster,
  type Service,
} from './ecs'
import {
  describeTargetHealth,
  listLoadBalancers,
  listTargetGroups,
  type LoadBalancer,
  type TargetGroup,
} from './elbv2'
import {
  listAutoScalingGroups,
  type AutoScalingGroup,
} from './autoscaling'
import {
  listHostedZones,
  listResourceRecordSets,
  type HostedZone,
  type ResourceRecordSet,
} from './route53'
import { listDbInstances, type DBInstance } from './rds'
import { listQueues, type SqsQueue } from './sqs'
import {
  GetPolicyCommand,
  GetPolicyVersionCommand,
  GetRolePolicyCommand,
  IAMClient,
  ListAttachedRolePoliciesCommand,
  ListRolePoliciesCommand,
  ListRolesCommand,
  ListUsersCommand,
  type Role,
  type User,
} from '@aws-sdk/client-iam'
import {
  LambdaClient,
  ListFunctionsCommand,
  type FunctionConfiguration,
} from '@aws-sdk/client-lambda'
import { emuCreds } from './emu'

const MAX_IAM_USERS = 400
const MAX_ROLES = 300
const MAX_LAMBDAS = 200

/** Parse tenant id from tags or crm-tenant-NNNN / arch-map names. */
export function tenantFromTags(
  tags: Array<{ Key?: string; Value?: string }> | undefined,
  nameHint?: string,
): string | undefined {
  const fromTag = tags?.find((t) => t.Key === 'awsbox:tenant')?.Value
  if (fromTag) return fromTag
  const hint = nameHint ?? ''
  const m =
    /^crm-tenant-(\d+)/i.exec(hint) ||
    /tenant-(\d+)/i.exec(hint) ||
    /^t(\d{4})\b/i.exec(hint)
  if (m?.[1]) return `t${m[1].padStart(4, '0')}`
  if (hint.includes('arch-map') || hint.startsWith('arch-map')) return 'lab'
  if (hint.includes('platform')) return 'platform'
  if (hint.includes('classic-3tier')) return 'classic'
  return undefined
}

export function listTenantsFromNodes(nodes: ArchNode[]): string[] {
  const set = new Set<string>()
  for (const n of nodes) {
    if (n.tenant) set.add(n.tenant)
  }
  return [...set].sort()
}

export type ArchLayer =
  | 'edge'
  | 'networking'
  | 'compute'
  | 'data'
  | 'messaging'
  | 'identity'

export type ArchNodeKind =
  | 'users'
  | 's3'
  | 'vpc'
  | 'igw'
  | 'nat'
  | 'alb'
  | 'ec2'
  | 'ecs-cluster'
  | 'rds'
  | 'sqs'
  | 'iam-role'
  | 'iam-user'
  | 'lambda'
  | 'route53'
  | 'asg'
  /** Aggregated IAM Allow fan-out — one box per role, not N yellow lines */
  | 'iam-allows'

export type ArchAllowTarget = {
  targetId: string
  targetLabel: string
  service: string
  proof: string
}

/** How we know the edge exists — never invent traffic. */
export type ArchEdgeKind =
  | 'attach'
  | 'route'
  | 'traffic'
  | 'identity'
  | 'allow'

export type ArchEdge = {
  id: string
  from: string
  to: string
  kind: ArchEdgeKind
  /** Human proof, shown in the sheet — e.g. policy statement / TG ARN */
  proof: string
}

export type TopologyGap = {
  id: string
  label: string
  detail: string
}

export type ArchNode = {
  id: string
  kind: ArchNodeKind
  layer: ArchLayer
  label: string
  status?: string
  arn?: string
  href?: string
  meta: Array<{ label: string; value: string }>
  vpcId?: string
  az?: string
  band?: 'public' | 'app' | 'data' | 'side'
  /** awsbox:tenant or parsed from crm-tenant-NNNN names */
  tenant?: string
  /** For iam-allows hubs: every identity Allow this role opens */
  allowBreakdown?: ArchAllowTarget[]
  /** Role this iam-allows hub belongs to */
  roleId?: string
}

export type AccountTopology = {
  fetchedAt: string
  vpcs: Vpc[]
  subnets: Subnet[]
  igws: InternetGateway[]
  nats: NatGateway[]
  routeTables: RouteTable[]
  loadBalancers: LoadBalancer[]
  targetGroups: TargetGroup[]
  clusters: Cluster[]
  services: Service[]
  databases: DBInstance[]
  queues: SqsQueue[]
  buckets: string[]
  roles: Role[]
  iamUsers: User[]
  lambdas: FunctionConfiguration[]
  instances: Instance[]
  hostedZones: HostedZone[]
  zoneRecords: Array<{ zoneId: string; records: ResourceRecordSet[] }>
  autoScalingGroups: AutoScalingGroup[]
  /** TG ARN → registered target instance ids (DescribeTargetHealth) */
  tgTargets: Record<string, string[]>
  nodes: ArchNode[]
  edges: ArchEdge[]
  gaps: TopologyGap[]
}

type RoleAllows = {
  roleArn: string
  roleName: string
  /** Normalized service keys: s3 | sqs | rds | "*" */
  services: Set<string>
  proofs: string[]
}

function iamClient() {
  return new IAMClient(emuCreds())
}

function asList(v: string | string[] | undefined): string[] {
  if (!v) return []
  return Array.isArray(v) ? v : [v]
}

function parseIamPolicyDocument(raw: unknown): unknown {
  if (raw == null) return null
  if (typeof raw !== 'string') return raw
  try {
    return JSON.parse(decodeURIComponent(raw))
  } catch {
    try {
      return JSON.parse(raw)
    } catch {
      return null
    }
  }
}

function servicesFromActions(actions: string[]): Set<string> {
  const out = new Set<string>()
  for (const raw of actions) {
    const a = raw.toLowerCase()
    if (a === '*' || a === '*:*') {
      out.add('*')
      continue
    }
    const svc = a.split(':')[0]
    if (svc === 's3' || svc === 'sqs' || svc === 'rds' || svc === 'iam') {
      out.add(svc)
    }
  }
  return out
}

function parsePolicyDocument(doc: unknown, proofs: string[], label: string): Set<string> {
  const services = new Set<string>()
  if (!doc || typeof doc !== 'object') return services
  const record = doc
  const statements = 'Statement' in record ? record.Statement : undefined
  const list = Array.isArray(statements)
    ? statements
    : statements
      ? [statements]
      : []
  for (const stmt of list) {
    if (!stmt || typeof stmt !== 'object') continue
    const effect =
      'Effect' in stmt && typeof stmt.Effect === 'string' ? stmt.Effect : ''
    if (effect.toLowerCase() !== 'allow') continue
    const actions = asList(
      'Action' in stmt && (typeof stmt.Action === 'string' || Array.isArray(stmt.Action))
        ? stmt.Action
        : undefined,
    )
    const resources = asList(
      'Resource' in stmt &&
        (typeof stmt.Resource === 'string' || Array.isArray(stmt.Resource))
        ? stmt.Resource
        : undefined,
    )
    const found = servicesFromActions(actions)
    for (const s of found) services.add(s)
    if (found.size > 0) {
      proofs.push(
        `${label}: Allow ${actions.join(', ')} on ${resources.join(', ') || '*'}`,
      )
    }
  }
  return services
}

async function loadRoleAllows(role: Role): Promise<RoleAllows | null> {
  const roleName = role.RoleName
  const roleArn = role.Arn
  if (!roleName || !roleArn) return null
  const services = new Set<string>()
  const proofs: string[] = []

  try {
    const inline = await iamClient().send(
      new ListRolePoliciesCommand({ RoleName: roleName }),
    )
    for (const policyName of inline.PolicyNames ?? []) {
      const got = await iamClient().send(
        new GetRolePolicyCommand({ RoleName: roleName, PolicyName: policyName }),
      )
      const doc = parseIamPolicyDocument(got.PolicyDocument)
      for (const s of parsePolicyDocument(doc, proofs, `inline:${policyName}`)) {
        services.add(s)
      }
    }
  } catch {
    /* role may lack inline policies */
  }

  try {
    const attached = await iamClient().send(
      new ListAttachedRolePoliciesCommand({ RoleName: roleName }),
    )
    for (const p of attached.AttachedPolicies ?? []) {
      if (!p.PolicyArn) continue
      const meta = await iamClient().send(
        new GetPolicyCommand({ PolicyArn: p.PolicyArn }),
      )
      const ver = meta.Policy?.DefaultVersionId
      if (!ver) continue
      const version = await iamClient().send(
        new GetPolicyVersionCommand({
          PolicyArn: p.PolicyArn,
          VersionId: ver,
        }),
      )
      const doc = parseIamPolicyDocument(version.PolicyVersion?.Document)
      for (const s of parsePolicyDocument(
        doc,
        proofs,
        `attached:${p.PolicyName ?? p.PolicyArn}`,
      )) {
        services.add(s)
      }
    }
  } catch {
    /* attached policy read failed */
  }

  return { roleArn, roleName, services, proofs }
}

async function listWorkloadRoles(): Promise<Role[]> {
  const out = await iamClient().send(
    new ListRolesCommand({ MaxItems: MAX_ROLES }),
  )
  return out.Roles ?? []
}

function isWorkloadRoleName(name: string): boolean {
  const n = name.toLowerCase()
  // Do not match bare "lambda" / leftover platform roles — only seed-shaped
  // names, or roles attached via taskRole / Lambda Role later.
  return (
    n.includes('task') ||
    n.includes('arch-map') ||
    n.includes('classic-3tier') ||
    n.startsWith('crm-') ||
    n.includes('backup') ||
    n.includes('mobile')
  )
}

async function listIamUsersCapped(): Promise<User[]> {
  const out = await iamClient().send(
    new ListUsersCommand({ MaxItems: MAX_IAM_USERS }),
  )
  return out.Users ?? []
}

async function listLambdasCapped(): Promise<FunctionConfiguration[]> {
  const client = new LambdaClient(emuCreds())
  const out = await client.send(
    new ListFunctionsCommand({ MaxItems: MAX_LAMBDAS }),
  )
  return out.Functions ?? []
}

function pickPrimaryVpc(vpcs: Vpc[]): Vpc | undefined {
  const tagged = vpcs.find((v) =>
    v.Tags?.some(
      (t) => t.Key === 'awsbox:architecture-map' && t.Value === '1',
    ),
  )
  if (tagged) return tagged
  const named = vpcs.find((v) =>
    nameTag(v.Tags).toLowerCase().includes('arch-map'),
  )
  if (named) return named
  return vpcs.find((v) => v.IsDefault !== true) ?? vpcs[0]
}

function pushEdge(
  edges: ArchEdge[],
  seen: Set<string>,
  from: string,
  to: string,
  kind: ArchEdgeKind,
  proof: string,
) {
  if (!from || !to || from === to) return
  const id = `${kind}:${from}->${to}`
  if (seen.has(id)) return
  seen.add(id)
  edges.push({ id, from, to, kind, proof })
}

function buildNodes(
  topo: Omit<AccountTopology, 'nodes' | 'edges' | 'gaps' | 'fetchedAt'>,
): ArchNode[] {
  const nodes: ArchNode[] = [
    {
      id: 'users',
      kind: 'users',
      layer: 'edge',
      label: 'Internet',
      meta: [
        {
          label: 'Type',
          value: 'Entry marker — only linked when an internet-facing LB exists',
        },
      ],
    },
  ]

  const primary = pickPrimaryVpc(topo.vpcs)

  for (const name of topo.buckets) {
    const tenant = tenantFromTags(undefined, name)
    nodes.push({
      id: `s3:${name}`,
      kind: 's3',
      layer: 'edge',
      label: name,
      href: `/buckets/${encodeURIComponent(name)}`,
      tenant,
      meta: [
        { label: 'Type', value: 'S3 bucket' },
        { label: 'Name', value: name },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  // Show every VPC as a node (honesty: not only the “demo” one)
  for (const vpc of topo.vpcs) {
    if (!vpc.VpcId) continue
    const tenant = tenantFromTags(vpc.Tags, nameTag(vpc.Tags))
    nodes.push({
      id: `vpc:${vpc.VpcId}`,
      kind: 'vpc',
      layer: 'networking',
      label:
        nameTag(vpc.Tags) !== '—'
          ? nameTag(vpc.Tags)
          : vpc.IsDefault
            ? `default ${vpc.VpcId}`
            : vpc.VpcId,
      status: vpc.State,
      href: `/ec2/vpcs/${encodeURIComponent(vpc.VpcId)}`,
      vpcId: vpc.VpcId,
      tenant,
      meta: [
        { label: 'Type', value: 'VPC' },
        { label: 'VPC ID', value: vpc.VpcId },
        { label: 'CIDR', value: vpc.CidrBlock ?? '—' },
        { label: 'Default', value: vpc.IsDefault ? 'yes' : 'no' },
        { label: 'State', value: vpc.State ?? '—' },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const igw of topo.igws) {
    const id = igw.InternetGatewayId ?? 'igw'
    const attached = igw.Attachments?.[0]
    const tenant = tenantFromTags(igw.Tags, nameTag(igw.Tags))
    nodes.push({
      id: `igw:${id}`,
      kind: 'igw',
      layer: 'networking',
      label: nameTag(igw.Tags) !== '—' ? nameTag(igw.Tags) : id,
      status: attached?.State,
      vpcId: attached?.VpcId,
      band: 'public',
      tenant,
      meta: [
        { label: 'Type', value: 'Internet Gateway' },
        { label: 'ID', value: id },
        { label: 'VPC', value: attached?.VpcId ?? '—' },
        { label: 'State', value: attached?.State ?? '—' },
      ],
    })
  }

  for (const nat of topo.nats) {
    const id = nat.NatGatewayId ?? 'nat'
    const tenant = tenantFromTags(nat.Tags, nameTag(nat.Tags))
    nodes.push({
      id: `nat:${id}`,
      kind: 'nat',
      layer: 'networking',
      label: nameTag(nat.Tags) !== '—' ? nameTag(nat.Tags) : id,
      status: nat.State,
      vpcId: nat.VpcId,
      tenant,
      az: nat.SubnetId
        ? topo.subnets.find((s) => s.SubnetId === nat.SubnetId)?.AvailabilityZone
        : undefined,
      band: 'public',
      meta: [
        { label: 'Type', value: 'NAT Gateway' },
        { label: 'ID', value: id },
        { label: 'State', value: nat.State ?? '—' },
        { label: 'Subnet', value: nat.SubnetId ?? '—' },
        { label: 'VPC', value: nat.VpcId ?? '—' },
      ],
    })
  }

  for (const lb of topo.loadBalancers) {
    const arn = lb.LoadBalancerArn ?? lb.LoadBalancerName ?? 'alb'
    const tenant = tenantFromTags(undefined, lb.LoadBalancerName)
    nodes.push({
      id: `alb:${arn}`,
      kind: 'alb',
      layer: 'networking',
      label: lb.LoadBalancerName ?? arn,
      status: lb.State?.Code,
      arn: lb.LoadBalancerArn,
      href: '/ec2/load-balancers',
      vpcId: lb.VpcId,
      band: 'public',
      tenant,
      meta: [
        { label: 'Type', value: `${lb.Type ?? 'application'} load balancer` },
        { label: 'Name', value: lb.LoadBalancerName ?? '—' },
        { label: 'DNS', value: lb.DNSName ?? '—' },
        { label: 'Scheme', value: lb.Scheme ?? '—' },
        { label: 'State', value: lb.State?.Code ?? '—' },
        { label: 'VPC', value: lb.VpcId ?? '—' },
      ],
    })
  }

  for (const inst of topo.instances) {
    const id = inst.InstanceId
    if (!id) continue
    const state = inst.State?.Name
    if (state === 'terminated' || state === 'shutting-down') continue
    const label = nameTag(inst.Tags) ?? id
    const tenant = tenantFromTags(inst.Tags, label)
    nodes.push({
      id: `ec2:${id}`,
      kind: 'ec2',
      layer: 'compute',
      label,
      status: state,
      arn: undefined,
      href: `/ec2/instances/${encodeURIComponent(id)}`,
      vpcId: inst.VpcId,
      az: inst.Placement?.AvailabilityZone,
      band: 'public',
      tenant,
      meta: [
        { label: 'Type', value: 'EC2 instance' },
        { label: 'ID', value: id },
        { label: 'State', value: state ?? '—' },
        { label: 'Instance type', value: inst.InstanceType ?? '—' },
        { label: 'Private IP', value: inst.PrivateIpAddress ?? '—' },
        { label: 'Subnet', value: inst.SubnetId ?? '—' },
        { label: 'VPC', value: inst.VpcId ?? '—' },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const cluster of topo.clusters) {
    const name = cluster.clusterName ?? cluster.clusterArn ?? 'cluster'
    const svcCount = topo.services.filter(
      (s) =>
        (s.clusterArn ?? '').endsWith(`/${name}`) ||
        s.clusterArn === cluster.clusterArn,
    ).length
    const running = cluster.runningTasksCount ?? 0
    // Orphan inactive bridge clusters clutter the classic / platform story
    if (
      (cluster.status === 'INACTIVE' || cluster.status === 'inactive') &&
      running === 0 &&
      svcCount === 0
    ) {
      continue
    }
    const tenant = tenantFromTags(undefined, name)
    nodes.push({
      id: `ecs:${name}`,
      kind: 'ecs-cluster',
      layer: 'compute',
      label: name,
      status: cluster.status,
      arn: cluster.clusterArn,
      href: `/ecs/clusters/${encodeURIComponent(name)}`,
      band: 'app',
      tenant,
      meta: [
        { label: 'Type', value: 'ECS cluster' },
        { label: 'Name', value: name },
        { label: 'Status', value: cluster.status ?? '—' },
        {
          label: 'Running tasks',
          value: String(running),
        },
        {
          label: 'Services',
          value: String(svcCount),
        },
      ],
    })
  }

  for (const fn of topo.lambdas) {
    const name = fn.FunctionName ?? 'lambda'
    const tenant = tenantFromTags(undefined, name)
    nodes.push({
      id: `lambda:${name}`,
      kind: 'lambda',
      layer: 'compute',
      label: name,
      status: fn.State ?? 'Active',
      arn: fn.FunctionArn,
      href: `/lambda/functions/${encodeURIComponent(name)}`,
      band: 'app',
      tenant,
      meta: [
        { label: 'Type', value: 'Lambda function' },
        { label: 'Name', value: name },
        { label: 'Runtime', value: fn.Runtime ?? '—' },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const db of topo.databases) {
    const id = db.DBInstanceIdentifier ?? 'db'
    const tenant = tenantFromTags(db.TagList, id)
    nodes.push({
      id: `rds:${id}`,
      kind: 'rds',
      layer: 'data',
      label: id,
      status: db.DBInstanceStatus,
      arn: db.DBInstanceArn,
      href: `/rds/databases/${encodeURIComponent(id)}`,
      vpcId: db.DBSubnetGroup?.VpcId,
      band: 'data',
      tenant,
      meta: [
        { label: 'Type', value: `RDS ${db.Engine ?? 'database'}` },
        { label: 'Identifier', value: id },
        { label: 'Class', value: db.DBInstanceClass ?? '—' },
        { label: 'Status', value: db.DBInstanceStatus ?? '—' },
        { label: 'Engine', value: db.Engine ?? '—' },
        { label: 'VPC', value: db.DBSubnetGroup?.VpcId ?? '—' },
        {
          label: 'Publicly accessible',
          value: db.PubliclyAccessible ? 'yes' : 'no',
        },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const q of topo.queues) {
    const tenant = tenantFromTags(undefined, q.name)
    nodes.push({
      id: `sqs:${q.url}`,
      kind: 'sqs',
      layer: 'messaging',
      label: q.name,
      arn: q.arn,
      band: 'side',
      tenant,
      meta: [
        { label: 'Type', value: 'SQS queue' },
        { label: 'Name', value: q.name },
        { label: 'URL', value: q.url },
        { label: 'ARN', value: q.arn ?? '—' },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const role of topo.roles) {
    const name = role.RoleName ?? 'role'
    const tenant = tenantFromTags(role.Tags, name)
    nodes.push({
      id: `role:${name}`,
      kind: 'iam-role',
      layer: 'identity',
      label: name,
      arn: role.Arn,
      band: 'side',
      tenant,
      meta: [
        { label: 'Type', value: 'IAM role' },
        { label: 'Name', value: name },
        { label: 'ARN', value: role.Arn ?? '—' },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const user of topo.iamUsers) {
    const name = user.UserName ?? 'user'
    const tenant = tenantFromTags(user.Tags, name)
    nodes.push({
      id: `iam-user:${name}`,
      kind: 'iam-user',
      layer: 'identity',
      label: name,
      arn: user.Arn,
      band: 'side',
      tenant,
      href: '/iam',
      meta: [
        { label: 'Type', value: 'IAM user (staff sample)' },
        { label: 'Name', value: name },
        { label: 'ARN', value: user.Arn ?? '—' },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const zone of topo.hostedZones) {
    const rawId = zone.Id ?? ''
    const zoneId = rawId.replace(/^\/hostedzone\//, '')
    if (!zoneId) continue
    const name = (zone.Name ?? zoneId).replace(/\.$/, '')
    const tenant = tenantFromTags(undefined, name)
    nodes.push({
      id: `r53:${zoneId}`,
      kind: 'route53',
      layer: 'edge',
      label: name,
      tenant,
      meta: [
        { label: 'Type', value: 'Route 53 hosted zone' },
        { label: 'Name', value: name },
        { label: 'Zone ID', value: zoneId },
        {
          label: 'Private',
          value: zone.Config?.PrivateZone ? 'yes' : 'no',
        },
        {
          label: 'Record sets',
          value: String(zone.ResourceRecordSetCount ?? '—'),
        },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  for (const asg of topo.autoScalingGroups) {
    const name = asg.AutoScalingGroupName
    if (!name) continue
    const tags = (asg.Tags ?? []).map((t) => ({
      Key: t.Key,
      Value: t.Value,
    }))
    const tenant = tenantFromTags(tags, name)
    const subnetIds = (asg.VPCZoneIdentifier ?? '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean)
    const vpcId = topo.subnets.find(
      (s) => s.SubnetId && subnetIds.includes(s.SubnetId),
    )?.VpcId
    nodes.push({
      id: `asg:${name}`,
      kind: 'asg',
      layer: 'compute',
      label: name,
      arn: asg.AutoScalingGroupARN,
      vpcId,
      band: name.includes('web') ? 'public' : 'app',
      tenant,
      meta: [
        { label: 'Type', value: 'Auto Scaling group' },
        { label: 'Name', value: name },
        {
          label: 'Desired / min / max',
          value: `${asg.DesiredCapacity ?? '—'} / ${asg.MinSize ?? '—'} / ${asg.MaxSize ?? '—'}`,
        },
        {
          label: 'Instances',
          value: String(asg.Instances?.length ?? 0),
        },
        {
          label: 'Target groups',
          value: String(asg.TargetGroupARNs?.length ?? 0),
        },
        ...(tenant ? [{ label: 'Tenant', value: tenant }] : []),
      ],
    })
  }

  void primary
  return nodes
}

function buildEdges(
  topo: Omit<AccountTopology, 'nodes' | 'edges' | 'gaps' | 'fetchedAt'>,
  nodes: ArchNode[],
  roleAllows: RoleAllows[],
): { edges: ArchEdge[]; gaps: TopologyGap[] } {
  const edges: ArchEdge[] = []
  const seen = new Set<string>()
  const gaps: TopologyGap[] = []
  const byId = new Map(nodes.map((n) => [n.id, n]))
  const has = (id: string) => byId.has(id)

  // IGW attachments
  for (const igw of topo.igws) {
    const igwId = igw.InternetGatewayId
    if (!igwId) continue
    for (const att of igw.Attachments ?? []) {
      if (!att.VpcId) continue
      const from = `igw:${igwId}`
      const to = `vpc:${att.VpcId}`
      if (has(from) && has(to)) {
        pushEdge(
          edges,
          seen,
          from,
          to,
          'attach',
          `IGW attachment state=${att.State ?? 'unknown'}`,
        )
      }
    }
  }

  // NAT → VPC
  for (const nat of topo.nats) {
    if (!nat.NatGatewayId || !nat.VpcId) continue
    const from = `nat:${nat.NatGatewayId}`
    const to = `vpc:${nat.VpcId}`
    if (has(from) && has(to)) {
      pushEdge(
        edges,
        seen,
        from,
        to,
        'attach',
        `NAT Gateway in VPC ${nat.VpcId} (subnet ${nat.SubnetId ?? '—'})`,
      )
    }
  }

  // ALB → VPC; Internet → ALB when internet-facing and no R53 alias already fronts it
  const albDnsFrontedByR53 = new Set<string>()
  const lbDnsLookup = new Map(
    topo.loadBalancers
      .filter((lb) => lb.DNSName && lb.LoadBalancerArn)
      .map((lb) => [lb.DNSName!.toLowerCase().replace(/\.$/, ''), lb.LoadBalancerArn!]),
  )
  for (const zr of topo.zoneRecords) {
    for (const rr of zr.records) {
      if (rr.Type === 'NS' || rr.Type === 'SOA') continue
      const vals: string[] = []
      if (rr.AliasTarget?.DNSName) vals.push(rr.AliasTarget.DNSName)
      for (const rec of rr.ResourceRecords ?? []) {
        if (rec.Value) vals.push(rec.Value)
      }
      for (const raw of vals) {
        const val = raw.toLowerCase().replace(/\.$/, '')
        for (const [dns, arn] of lbDnsLookup) {
          if (val === dns || val.includes(dns)) albDnsFrontedByR53.add(arn)
        }
      }
    }
  }

  for (const lb of topo.loadBalancers) {
    const arn = lb.LoadBalancerArn
    if (!arn) continue
    const albId = `alb:${arn}`
    if (lb.VpcId && has(albId) && has(`vpc:${lb.VpcId}`)) {
      pushEdge(
        edges,
        seen,
        albId,
        `vpc:${lb.VpcId}`,
        'attach',
        `Load balancer VpcId=${lb.VpcId}`,
      )
    }
    if (
      lb.Scheme === 'internet-facing' &&
      has('users') &&
      has(albId) &&
      !albDnsFrontedByR53.has(arn)
    ) {
      pushEdge(
        edges,
        seen,
        'users',
        albId,
        'traffic',
        `ALB Scheme=internet-facing (public entry)`,
      )
    }
  }

  // Default route → IGW / NAT
  for (const rtb of topo.routeTables) {
    for (const route of rtb.Routes ?? []) {
      if (route.DestinationCidrBlock !== '0.0.0.0/0') continue
      if (route.GatewayId?.startsWith('igw-')) {
        const igwNode = `igw:${route.GatewayId}`
        const vpcId = rtb.VpcId
        if (vpcId && has(igwNode) && has(`vpc:${vpcId}`)) {
          pushEdge(
            edges,
            seen,
            `vpc:${vpcId}`,
            igwNode,
            'route',
            `Route table ${rtb.RouteTableId}: 0.0.0.0/0 → ${route.GatewayId}`,
          )
        }
      }
      if (route.NatGatewayId) {
        const natNode = `nat:${route.NatGatewayId}`
        const vpcId = rtb.VpcId
        if (vpcId && has(natNode) && has(`vpc:${vpcId}`)) {
          pushEdge(
            edges,
            seen,
            `vpc:${vpcId}`,
            natNode,
            'route',
            `Route table ${rtb.RouteTableId}: 0.0.0.0/0 → ${route.NatGatewayId}`,
          )
        }
      }
    }
  }

  // ALB → ECS via target group + service.loadBalancers
  const tgByArn = new Map(
    topo.targetGroups
      .filter((t) => t.TargetGroupArn)
      .map((t) => [t.TargetGroupArn!, t]),
  )
  for (const svc of topo.services) {
    const clusterName =
      svc.clusterArn?.split('/').pop() ??
      nodes.find(
        (n) =>
          n.kind === 'ecs-cluster' &&
          (n.arn === svc.clusterArn || n.label === svc.clusterArn),
      )?.label
    if (!clusterName) continue
    const ecsId = `ecs:${clusterName}`
    if (!has(ecsId)) continue

    for (const lbRef of svc.loadBalancers ?? []) {
      const tgArn = lbRef.targetGroupArn
      if (!tgArn) continue
      const tg = tgByArn.get(tgArn)
      const lbArns = tg?.LoadBalancerArns ?? []
      for (const lbArn of lbArns) {
        const albId = `alb:${lbArn}`
        if (has(albId)) {
          pushEdge(
            edges,
            seen,
            albId,
            ecsId,
            'traffic',
            `ECS service ${svc.serviceName} → target group ${tg?.TargetGroupName ?? tgArn}`,
          )
        }
      }
      if (lbArns.length === 0) {
        gaps.push({
          id: `tg-unattached:${tgArn}`,
          label: 'Target group not on a load balancer',
          detail: `Service ${svc.serviceName} references ${tgArn}, but DescribeTargetGroups listed no LoadBalancerArns`,
        })
      }
    }
  }

  // ALB → EC2 via DescribeTargetHealth (classic ASG / instance targets)
  for (const [tgArn, instanceIds] of Object.entries(topo.tgTargets)) {
    const tg = tgByArn.get(tgArn)
    const lbArns = tg?.LoadBalancerArns ?? []
    for (const lbArn of lbArns) {
      const albId = `alb:${lbArn}`
      if (!has(albId)) continue
      for (const iid of instanceIds) {
        const ec2Id = `ec2:${iid}`
        if (has(ec2Id)) {
          pushEdge(
            edges,
            seen,
            albId,
            ec2Id,
            'traffic',
            `Target group ${tg?.TargetGroupName ?? tgArn} registers ${iid}`,
          )
        }
      }
    }
  }

  // ASG → EC2 members; ASG → TG → ALB
  for (const asg of topo.autoScalingGroups) {
    const name = asg.AutoScalingGroupName
    if (!name) continue
    const asgId = `asg:${name}`
    if (!has(asgId)) continue
    for (const inst of asg.Instances ?? []) {
      const iid = inst.InstanceId
      if (!iid) continue
      const ec2Id = `ec2:${iid}`
      if (has(ec2Id)) {
        pushEdge(
          edges,
          seen,
          asgId,
          ec2Id,
          'attach',
          `ASG ${name} InstanceId=${iid} LifecycleState=${inst.LifecycleState ?? '—'}`,
        )
      }
    }
    for (const tgArn of asg.TargetGroupARNs ?? []) {
      const tg = tgByArn.get(tgArn)
      for (const lbArn of tg?.LoadBalancerArns ?? []) {
        const albId = `alb:${lbArn}`
        if (has(albId)) {
          pushEdge(
            edges,
            seen,
            albId,
            asgId,
            'traffic',
            `ASG ${name} TargetGroupARNs → ${tg?.TargetGroupName ?? tgArn}`,
          )
        }
      }
    }
  }

  // Route 53 → ALB / S3 from alias / CNAME records; Users → R53
  const lbByDns = new Map(
    topo.loadBalancers
      .filter((lb) => lb.DNSName && lb.LoadBalancerArn)
      .map((lb) => [lb.DNSName!.toLowerCase().replace(/\.$/, ''), lb]),
  )
  for (const zr of topo.zoneRecords) {
    const r53Id = `r53:${zr.zoneId}`
    if (!has(r53Id)) continue
    if (has('users')) {
      pushEdge(
        edges,
        seen,
        'users',
        r53Id,
        'traffic',
        `Public DNS entry via hosted zone ${zr.zoneId}`,
      )
    }
    for (const rr of zr.records) {
      if (rr.Type === 'NS' || rr.Type === 'SOA') continue
      const aliasDns = rr.AliasTarget?.DNSName?.toLowerCase().replace(/\.$/, '')
      if (aliasDns) {
        for (const [dns, lb] of lbByDns) {
          if (aliasDns === dns || aliasDns.endsWith(`.${dns}`) || dns.endsWith(`.${aliasDns}`)) {
            const albId = `alb:${lb.LoadBalancerArn}`
            if (has(albId)) {
              pushEdge(
                edges,
                seen,
                r53Id,
                albId,
                'traffic',
                `R53 ${rr.Name} ${rr.Type} alias → ${lb.DNSName}`,
              )
            }
          }
        }
      }
      for (const rec of rr.ResourceRecords ?? []) {
        const val = (rec.Value ?? '').toLowerCase().replace(/\.$/, '')
        if (!val) continue
        for (const [dns, lb] of lbByDns) {
          if (val === dns || val.includes(dns)) {
            const albId = `alb:${lb.LoadBalancerArn}`
            if (has(albId)) {
              pushEdge(
                edges,
                seen,
                r53Id,
                albId,
                'traffic',
                `R53 ${rr.Name} ${rr.Type} → ${rec.Value}`,
              )
            }
          }
        }
        const bucketMatch = /^([a-z0-9.-]+)\.s3[.-]/.exec(val)
        if (bucketMatch) {
          const bid = `s3:${bucketMatch[1]}`
          if (has(bid)) {
            pushEdge(
              edges,
              seen,
              r53Id,
              bid,
              'traffic',
              `R53 ${rr.Name} ${rr.Type} → ${rec.Value}`,
            )
          }
        }
      }
    }
  }

  // Role Allow → hub box + edges to real targets (tenant-scoped so org seed
  // does not spray every role onto every account bucket).
  for (const allow of roleAllows) {
    const roleId = `role:${allow.roleName}`
    if (!has(roleId)) continue

    const proof = allow.proofs[0] ?? 'IAM Allow'
    const star = allow.services.has('*')
    const breakdown: ArchAllowTarget[] = []
    const roleNode = byId.get(roleId)
    const roleTenant = roleNode?.tenant

    const pushTargets = (service: string, kind: ArchNodeKind) => {
      for (const n of nodes.filter((x) => x.kind === kind)) {
        if (roleTenant) {
          if (!n.tenant || n.tenant !== roleTenant) continue
        }
        breakdown.push({
          targetId: n.id,
          targetLabel: n.label,
          service,
          proof,
        })
      }
    }

    if (star || allow.services.has('s3')) pushTargets('s3', 's3')
    if (star || allow.services.has('sqs')) pushTargets('sqs', 'sqs')
    if (star || allow.services.has('rds')) pushTargets('rds', 'rds')

    if (breakdown.length === 0) {
      gaps.push({
        id: `role-no-allows:${allow.roleName}`,
        label: `Role ${allow.roleName} has no parsed Allow actions`,
        detail:
          'No inline/attached Allow we could map to S3/SQS/RDS — either empty or actions outside that set',
      })
      continue
    }

    const byService = new Map<string, number>()
    for (const b of breakdown) {
      byService.set(b.service, (byService.get(b.service) ?? 0) + 1)
    }
    const summary = [...byService.entries()]
      .map(([svc, n]) => `${svc}×${n}`)
      .join(', ')

    const hubId = `iam-allows:${allow.roleName}`
    nodes.push({
      id: hubId,
      kind: 'iam-allows',
      layer: 'identity',
      label: `IAM Allows (${breakdown.length})`,
      band: 'side',
      tenant: roleNode?.tenant,
      roleId,
      allowBreakdown: breakdown,
      meta: [
        { label: 'Type', value: 'IAM Allow hub' },
        { label: 'Role', value: allow.roleName },
        { label: 'Targets', value: summary },
        { label: 'Count', value: String(breakdown.length) },
        {
          label: 'Note',
          value: roleTenant
            ? `Scoped to tenant ${roleTenant} — lines go to each target`
            : 'Lines go to each Allow target on the map',
        },
        ...allow.proofs.slice(0, 3).map((p, i) => ({
          label: i === 0 ? 'Proof' : `Proof ${i + 1}`,
          value: p,
        })),
      ],
    })
    byId.set(hubId, nodes[nodes.length - 1]!)

    pushEdge(
      edges,
      seen,
      roleId,
      hubId,
      'allow',
      `${breakdown.length} resources via IAM Allow (${summary})`,
    )
    for (const b of breakdown) {
      if (!has(b.targetId)) continue
      pushEdge(
        edges,
        seen,
        hubId,
        b.targetId,
        'allow',
        `${allow.roleName} → ${b.targetLabel} (${b.service}): ${b.proof}`,
      )
    }
  }

  // Same-VPC RDS + ECS without IAM/SG proof → gap, not a fake arrow
  for (const db of topo.databases) {
    const vpcId = db.DBSubnetGroup?.VpcId
    if (!vpcId) continue
    const ecsInStory = nodes.filter((n) => n.kind === 'ecs-cluster')
    if (ecsInStory.length === 0) continue
    const rdsId = `rds:${db.DBInstanceIdentifier}`
    const hasAllow = nodes.some(
      (n) =>
        n.kind === 'iam-allows' &&
        n.allowBreakdown?.some((b) => b.targetId === rdsId),
    )
    if (!hasAllow) {
      gaps.push({
        id: `rds-path:${db.DBInstanceIdentifier}`,
        label: `No proven compute→${db.DBInstanceIdentifier} path`,
        detail:
          'RDS shares account/VPC space with ECS nodes, but there is no IAM Allow (or SG peer — not mapped yet) proving access. Not drawn as traffic.',
      })
    }
  }

  // SQS with no role Allow and no event source mapped
  for (const q of topo.queues) {
    const qid = `sqs:${q.url}`
    const linked =
      edges.some((e) => e.to === qid || e.from === qid) ||
      nodes.some(
        (n) =>
          n.kind === 'iam-allows' &&
          n.allowBreakdown?.some((b) => b.targetId === qid),
      )
    if (!linked) {
      gaps.push({
        id: `sqs-orphan:${q.name}`,
        label: `Queue ${q.name} has no proven producer/consumer edge`,
        detail:
          'No IAM Allow from a role on the map, and event-source mappings are not read yet',
      })
    }
  }

  gaps.push({
    id: 'gap-sg',
    label: 'Security group peer rules not on the map yet',
    detail:
      'SG ingress from another SG / CIDR can open paths the happy-path diagram omits — next honesty layer',
  })
  gaps.push({
    id: 'gap-resource-policies',
    label: 'Resource policies (S3 bucket / SQS / RDS) not parsed yet',
    detail:
      'Identity policy Allows are shown; resource-based policies can add more principals',
  })

  return { edges, gaps }
}

async function enrichServicesAndRoles(
  clusters: Cluster[],
  roles: Role[],
): Promise<{
  services: Service[]
  roleAllows: RoleAllows[]
  taskRoleEdges: Array<{ clusterName: string; roleArn: string; proof: string }>
}> {
  const services: Service[] = []
  const taskRoleEdges: Array<{
    clusterName: string
    roleArn: string
    proof: string
  }> = []

  for (const cluster of clusters) {
    const name = cluster.clusterName
    if (!name) continue
    const arns = await listServiceArns(name)
    if (arns.length === 0) continue
    const described = await describeServices(name, arns)
    services.push(...described)

    for (const svc of described) {
      if (!svc.taskDefinition) continue
      try {
        const td = await describeTaskDefinition(svc.taskDefinition)
        const proofs: Array<{ arn?: string; which: string }> = [
          { arn: td?.taskRoleArn, which: 'taskRoleArn' },
          { arn: td?.executionRoleArn, which: 'executionRoleArn' },
        ]
        for (const p of proofs) {
          if (!p.arn) continue
          taskRoleEdges.push({
            clusterName: name,
            roleArn: p.arn,
            proof: `ECS service ${svc.serviceName} task definition ${svc.taskDefinition} ${p.which}`,
          })
        }
      } catch {
        /* task def missing */
      }
    }
  }

  // Roles that appear on task defs OR look workload-related
  const neededArns = new Set(taskRoleEdges.map((e) => e.roleArn))
  const workload = roles.filter((r) => {
    const n = r.RoleName ?? ''
    return neededArns.has(r.Arn ?? '') || isWorkloadRoleName(n)
  })

  const roleAllows: RoleAllows[] = []
  for (const role of workload) {
    const allows = await loadRoleAllows(role)
    if (allows) roleAllows.push(allows)
  }

  return { services, roleAllows, taskRoleEdges }
}

export async function fetchAccountTopology(): Promise<AccountTopology> {
  const [
    vpcs,
    subnets,
    igws,
    nats,
    routeTables,
    loadBalancers,
    targetGroups,
    clusterArns,
    databases,
    queues,
    bucketList,
    allRoles,
    iamUsers,
    lambdas,
    instances,
    hostedZones,
    autoScalingGroups,
  ] = await Promise.all([
    listVpcs(),
    listSubnets(),
    listInternetGateways(),
    listNatGateways(),
    listRouteTables(),
    listLoadBalancers(),
    listTargetGroups(),
    listClusterArns(),
    listDbInstances(),
    listQueues(),
    listBuckets(),
    listWorkloadRoles(),
    listIamUsersCapped(),
    listLambdasCapped(),
    listInstances(),
    listHostedZones(),
    listAutoScalingGroups(),
  ])

  const clusters = await describeClusters(clusterArns)
  const { services, roleAllows, taskRoleEdges } =
    await enrichServicesAndRoles(clusters, allRoles)

  const zoneRecords: Array<{ zoneId: string; records: ResourceRecordSet[] }> =
    []
  for (const zone of hostedZones) {
    const rawId = zone.Id ?? ''
    const zoneId = rawId.replace(/^\/hostedzone\//, '')
    if (!zoneId) continue
    try {
      const records = await listResourceRecordSets(zoneId)
      zoneRecords.push({ zoneId, records })
    } catch {
      /* zone list can fail on partial LocalEmu */
    }
  }

  const tgTargets: Record<string, string[]> = {}
  await Promise.all(
    targetGroups
      .map((tg) => tg.TargetGroupArn)
      .filter((arn): arn is string => Boolean(arn))
      .map(async (arn) => {
        try {
          const health = await describeTargetHealth(arn)
          const ids = health
            .map((h) => h.Target?.Id)
            .filter((id): id is string => Boolean(id) && id.startsWith('i-'))
          if (ids.length > 0) tgTargets[arn] = ids
        } catch {
          /* TG health optional */
        }
      }),
  )

  // Ensure roles referenced by task defs appear even if name filter missed them
  const roleByArn = new Map(allRoles.filter((r) => r.Arn).map((r) => [r.Arn!, r]))
  const roles: Role[] = []
  const seenRole = new Set<string>()
  for (const r of allRoles) {
    const n = r.RoleName ?? ''
    if (isWorkloadRoleName(n)) {
      if (r.RoleName && !seenRole.has(r.RoleName)) {
        seenRole.add(r.RoleName)
        roles.push(r)
      }
    }
  }
  for (const edge of taskRoleEdges) {
    const r = roleByArn.get(edge.roleArn)
    if (r?.RoleName && !seenRole.has(r.RoleName)) {
      seenRole.add(r.RoleName)
      roles.push(r)
    }
  }
  for (const fn of lambdas) {
    const roleArn = fn.Role
    if (!roleArn) continue
    const r = roleByArn.get(roleArn)
    if (r?.RoleName && !seenRole.has(r.RoleName)) {
      seenRole.add(r.RoleName)
      roles.push(r)
    }
  }

  const buckets = bucketList
    .map((b) => b.Name)
    .filter((n): n is string => Boolean(n))

  const base = {
    vpcs,
    subnets,
    igws,
    nats,
    routeTables,
    loadBalancers,
    targetGroups,
    clusters,
    services,
    databases,
    queues,
    buckets,
    roles,
    iamUsers,
    lambdas,
    instances,
    hostedZones,
    zoneRecords,
    autoScalingGroups,
    tgTargets,
  }

  const nodes = buildNodes(base)
  const { edges, gaps } = buildEdges(base, nodes, roleAllows)

  const seen = new Set(edges.map((e) => e.id))
  const roleNodeByArn = new Map(
    nodes.filter((n) => n.kind === 'iam-role' && n.arn).map((n) => [n.arn!, n.id]),
  )
  for (const tr of taskRoleEdges) {
    const roleId = roleNodeByArn.get(tr.roleArn)
    const ecsId = `ecs:${tr.clusterName}`
    if (roleId && nodes.some((n) => n.id === ecsId)) {
      pushEdge(edges, seen, ecsId, roleId, 'identity', tr.proof)
    }
  }

  for (const fn of lambdas) {
    const name = fn.FunctionName
    const roleArn = fn.Role
    if (!name || !roleArn) continue
    const roleId = roleNodeByArn.get(roleArn)
    const lambdaId = `lambda:${name}`
    if (roleId && nodes.some((n) => n.id === lambdaId)) {
      pushEdge(
        edges,
        seen,
        lambdaId,
        roleId,
        'identity',
        `Lambda ${name} execution role`,
      )
    }
  }

  return {
    ...base,
    fetchedAt: new Date().toISOString(),
    nodes,
    edges,
    gaps,
  }
}
