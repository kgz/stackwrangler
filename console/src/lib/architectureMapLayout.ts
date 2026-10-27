import ELK, { type ElkNode } from 'elkjs/lib/elk.bundled.js'
import type { ArchEdge, ArchNode } from './topology'

export type NodePos = { id: string; x: number; y: number }
export type VpcHull = {
  x: number
  y: number
  w: number
  h: number
  label: string
}

export type MapLayout = {
  positions: Map<string, NodePos>
  width: number
  height: number
  hull: VpcHull | null
}

const NODE_W = 120
const NODE_H = 96
const PAD = 40
const NODE_GAP = 72
const VPC_INSET = { top: 28, left: 20, bottom: 20, right: 20 }

const elk = new ELK()

function inVpc(n: ArchNode): boolean {
  return (
    n.kind === 'igw' ||
    n.kind === 'nat' ||
    n.kind === 'alb' ||
    n.kind === 'ec2' ||
    n.kind === 'asg' ||
    n.kind === 'ecs-cluster' ||
    n.kind === 'lambda' ||
    n.kind === 'rds'
  )
}

function isAllowEdge(e: ArchEdge): boolean {
  return e.kind === 'allow' || e.proof.includes('IAM Allow')
}

function boxesOverlap(a: NodePos, b: NodePos, gap = 24): boolean {
  return !(
    a.x + NODE_W + gap <= b.x ||
    b.x + NODE_W + gap <= a.x ||
    a.y + NODE_H + gap <= b.y ||
    b.y + NODE_H + gap <= a.y
  )
}

function placeClearOf(
  positions: Map<string, NodePos>,
  id: string,
  x: number,
  y: number,
  ignore: Set<string>,
): NodePos {
  let next = { id, x, y }
  for (let attempt = 0; attempt < 12; attempt++) {
    let hit = false
    for (const [otherId, other] of positions) {
      if (otherId === id || ignore.has(otherId)) continue
      if (boxesOverlap(next, other)) {
        hit = true
        next = { id, x: next.x + NODE_W + NODE_GAP, y: next.y }
        break
      }
    }
    if (!hit) break
  }
  positions.set(id, next)
  return next
}

/**
 * Park RDS at the VPC top-right and IAM roles that Allow it just outside
 * that corner. Do not drag S3/other outsides — R53→S3 traffic must stay
 * on the edge row, not through the IAM slot.
 */
function pinRdsBesideIamAllows(
  positions: Map<string, NodePos>,
  hull: VpcHull,
  nodes: ArchNode[],
  edges: ArchEdge[],
): VpcHull {
  const kindById = new Map(nodes.map((n) => [n.id, n.kind]))
  const rdsIds = nodes.filter((n) => n.kind === 'rds').map((n) => n.id)
  if (rdsIds.length === 0) return hull

  const rolesToRds = new Set<string>()
  for (const e of edges) {
    if (!isAllowEdge(e)) continue
    if (kindById.get(e.from) !== 'iam-role') continue
    if (kindById.get(e.to) !== 'rds') continue
    rolesToRds.add(e.from)
  }
  if (rolesToRds.size === 0) return hull

  const moved = new Set<string>()

  // Clear a right column inside the hull for RDS (stack if several).
  let innerRight = hull.x + VPC_INSET.left
  for (const [id, pos] of positions) {
    if (kindById.get(id) === 'rds') continue
    if (
      pos.x >= hull.x &&
      pos.x + NODE_W <= hull.x + hull.w + 1 &&
      pos.y >= hull.y &&
      pos.y + NODE_H <= hull.y + hull.h + 1
    ) {
      innerRight = Math.max(innerRight, pos.x + NODE_W + NODE_GAP)
    }
  }

  const rdsX = Math.max(innerRight, hull.x + VPC_INSET.left)
  let rdsY = hull.y + VPC_INSET.top
  for (const rdsId of rdsIds) {
    if (!positions.has(rdsId)) continue
    placeClearOf(positions, rdsId, rdsX, rdsY, moved)
    moved.add(rdsId)
    rdsY += NODE_H + NODE_GAP
  }

  let maxRdsRight = hull.x + VPC_INSET.left
  let maxRdsBottom = hull.y + VPC_INSET.top
  for (const rdsId of rdsIds) {
    const p = positions.get(rdsId)
    if (!p) continue
    maxRdsRight = Math.max(maxRdsRight, p.x + NODE_W)
    maxRdsBottom = Math.max(maxRdsBottom, p.y + NODE_H)
  }
  const nextHull: VpcHull = {
    ...hull,
    w: Math.max(hull.w, maxRdsRight + VPC_INSET.right - hull.x),
    h: Math.max(hull.h, maxRdsBottom + VPC_INSET.bottom - hull.y),
  }

  let roleY = hull.y + VPC_INSET.top
  for (const roleId of rolesToRds) {
    if (!positions.has(roleId)) continue
    placeClearOf(
      positions,
      roleId,
      nextHull.x + nextHull.w + NODE_GAP,
      roleY,
      moved,
    )
    moved.add(roleId)
    roleY += NODE_H + NODE_GAP
  }

  return nextHull
}

/** Layer hint so ELK keeps left→right flow like a mind map / data-flow. */
function layerHint(kind: ArchNode['kind']): string {
  switch (kind) {
    case 'users':
      return '0'
    case 'route53':
      return '1'
    case 's3':
      return '2'
    case 'igw':
    case 'nat':
    case 'alb':
      return '3'
    case 'asg':
      return '4'
    case 'ec2':
      return '5'
    case 'ecs-cluster':
    case 'lambda':
      return '6'
    case 'iam-role':
      return '7'
    case 'rds':
      return '8'
    case 'sqs':
      return '9'
    case 'iam-user':
      return '10'
    default:
      return '7'
  }
}

function flattenPositions(
  node: ElkNode,
  offsetX: number,
  offsetY: number,
  into: Map<string, NodePos>,
): void {
  const x = offsetX + (node.x ?? 0)
  const y = offsetY + (node.y ?? 0)
  if (node.id !== 'root' && node.id !== 'vpc-group') {
    into.set(node.id, { id: node.id, x, y })
  }
  for (const child of node.children ?? []) {
    // Children of compound nodes are relative to the parent
    const childOffsetX = node.id === 'root' ? offsetX : x
    const childOffsetY = node.id === 'root' ? offsetY : y
    flattenPositions(child, childOffsetX, childOffsetY, into)
  }
}

/**
 * Automatic layout via elkjs — feed nodes/edges, get non-overlapping positions.
 * https://www.eclipse.org/elk/reference/algorithms/org-eclipse-elk-layered.html
 */
export async function layoutArchitectureMap(
  nodes: ArchNode[],
  edges: ArchEdge[],
  vpcLabel: string,
): Promise<MapLayout> {
  const drawable = nodes.filter(
    (n) => n.kind !== 'iam-allows' && n.kind !== 'vpc',
  )
  const vpcKids = drawable.filter(inVpc)
  const outer = drawable.filter((n) => !inVpc(n))
  const ids = new Set(drawable.map((n) => n.id))

  const child = (n: ArchNode): ElkNode => ({
    id: n.id,
    width: NODE_W,
    height: NODE_H,
    layoutOptions: {
      'elk.layered.layering.layerConstraint': 'NONE',
      'org.eclipse.elk.layered.layering.layerConstraint': 'NONE',
      // Soft layer preference via node priority (higher = earlier for LEFT→RIGHT? use partition)
      'partitioning.partition': layerHint(n.kind),
    },
  })

  const children: ElkNode[] = outer.map(child)
  if (vpcKids.length > 0) {
    children.push({
      id: 'vpc-group',
      layoutOptions: {
        'elk.padding': '[top=28,left=20,bottom=20,right=20]',
        'partitioning.partition': '3',
      },
      children: vpcKids.map(child),
    })
  }

  // Allow edges are placed by pinRdsBesideIamAllows — keep them out of ELK
  // so they don't drag IAM/RDS across the VPC mid-band.
  const elkEdges = edges
    .filter((e) => ids.has(e.from) && ids.has(e.to) && !isAllowEdge(e))
    .map((e) => ({
      id: e.id,
      sources: [e.from],
      targets: [e.to],
    }))

  const graph: ElkNode = {
    id: 'root',
    layoutOptions: {
      'elk.algorithm': 'layered',
      'elk.direction': 'RIGHT',
      'elk.edgeRouting': 'ORTHOGONAL',
      'elk.spacing.nodeNode': '72',
      'elk.spacing.edgeNode': '40',
      'elk.spacing.edgeEdge': '28',
      'elk.layered.spacing.nodeNodeBetweenLayers': '120',
      'elk.layered.spacing.edgeNodeBetweenLayers': '56',
      'elk.layered.nodePlacement.strategy': 'NETWORK_SIMPLEX',
      'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
      'elk.layered.edgeRouting.selfLoopDistribution': 'EQUALLY',
      'elk.partitioning.activate': 'true',
      'elk.padding': '[top=32,left=32,bottom=48,right=32]',
      'elk.separateConnectedComponents': 'true',
      'elk.spacing.componentComponent': '88',
    },
    children,
    edges: elkEdges,
  }

  let laid: ElkNode
  try {
    laid = await elk.layout(graph)
  } catch {
    // Fallback: simple grid if elk fails
    const positions = new Map<string, NodePos>()
    drawable.forEach((n, i) => {
      positions.set(n.id, {
        id: n.id,
        x: PAD + (i % 6) * (NODE_W + 40),
        y: PAD + Math.floor(i / 6) * (NODE_H + 32),
      })
    })
    return {
      positions,
      width: 900,
      height: 500,
      hull: null,
    }
  }

  const positions = new Map<string, NodePos>()
  flattenPositions(laid, PAD, PAD, positions)

  let hull: VpcHull | null = null
  const vpcElk = laid.children?.find((c) => c.id === 'vpc-group')
  if (vpcElk && vpcKids.length > 0) {
    hull = {
      x: PAD + (vpcElk.x ?? 0),
      y: PAD + (vpcElk.y ?? 0),
      w: vpcElk.width ?? 0,
      h: vpcElk.height ?? 0,
      label: vpcLabel,
    }
    hull = pinRdsBesideIamAllows(positions, hull, drawable, edges)
  }

  let maxX = PAD
  let maxY = PAD
  for (const p of positions.values()) {
    maxX = Math.max(maxX, p.x + NODE_W)
    maxY = Math.max(maxY, p.y + NODE_H)
  }
  if (hull) {
    maxX = Math.max(maxX, hull.x + hull.w)
    maxY = Math.max(maxY, hull.y + hull.h)
  }

  return {
    positions,
    width: Math.max(560, maxX + PAD),
    height: Math.max(320, maxY + PAD),
    hull,
  }
}

const EDGE_KIND_RANK: Record<ArchEdge['kind'], number> = {
  traffic: 5,
  attach: 4,
  route: 3,
  identity: 2,
  allow: 1,
}

/** Collapse Allow hubs onto their roles for drawing (IAM sits mid-edge). */
export function edgesForMindMap(
  edges: ArchEdge[],
  nodes: ArchNode[],
): ArchEdge[] {
  const hubToRole = new Map<string, string>()
  const kindById = new Map(nodes.map((n) => [n.id, n.kind]))
  for (const n of nodes) {
    if (n.kind === 'iam-allows' && n.roleId) hubToRole.set(n.id, n.roleId)
  }

  // One drawn join per from→to (keeps strongest kind) — stops double gold lines
  const best = new Map<string, ArchEdge>()
  for (const e of edges) {
    const from = hubToRole.get(e.from) ?? e.from
    const to = hubToRole.get(e.to) ?? e.to
    if (from === to) continue
    const key = `${from}->${to}`
    const next = { ...e, id: `${key}:${e.kind}`, from, to }
    const prev = best.get(key)
    if (!prev || EDGE_KIND_RANK[next.kind] > EDGE_KIND_RANK[prev.kind]) {
      best.set(key, next)
    }
  }
  const out = [...best.values()]

  // Prefer ALB → ASG → EC2 over ALB → EC2 when both exist — the direct
  // join draws straight through the ASG box and looks like a broken stub.
  const asgMembers = new Map<string, Set<string>>()
  const albToAsg = new Map<string, Set<string>>()
  for (const e of out) {
    if (kindById.get(e.from) === 'asg' && kindById.get(e.to) === 'ec2') {
      const set = asgMembers.get(e.from) ?? new Set()
      set.add(e.to)
      asgMembers.set(e.from, set)
    }
    if (kindById.get(e.from) === 'alb' && kindById.get(e.to) === 'asg') {
      const set = albToAsg.get(e.from) ?? new Set()
      set.add(e.to)
      albToAsg.set(e.from, set)
    }
  }
  return out.filter((e) => {
    if (kindById.get(e.from) !== 'alb' || kindById.get(e.to) !== 'ec2') {
      return true
    }
    for (const asgId of albToAsg.get(e.from) ?? []) {
      if (asgMembers.get(asgId)?.has(e.to)) return false
    }
    return true
  })
}

export const EMPTY_LAYOUT: MapLayout = {
  positions: new Map(),
  width: 640,
  height: 360,
  hull: null,
}
