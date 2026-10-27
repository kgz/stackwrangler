import type { ArchEdge } from '../lib/topology'
import type { NodePos } from '../lib/architectureMapLayout'

/** Must match .arch-node width + icon geometry in ArchitectureMapPage.css */
const NODE_W = 120
const NODE_PAD = 4
const ICON = 48
const ICON_CX = NODE_W / 2
const ICON_CY = NODE_PAD + ICON / 2
const ICON_HALF = ICON / 2
const ARROW_PAD = 3
const STUB = 18
const PORT_GAP = 14
/**
 * IAM Allow hops shorter than this use the same local ortho as traffic.
 * Longer hops use a vertical-first outside L (clear of the VPC mid-band).
 */
const SHORT_ALLOW_PX = NODE_W * 2.5

type Pt = { x: number; y: number }
type Side = 'l' | 'r' | 't' | 'b'
type AllowRoute = 'local' | 'outside'

function centerOf(pos: NodePos | undefined): Pt | null {
  if (!pos) return null
  return { x: pos.x + ICON_CX, y: pos.y + ICON_CY }
}

function facingSide(from: Pt, to: Pt): Side {
  const dx = to.x - from.x
  const dy = to.y - from.y
  if (Math.abs(dx) >= Math.abs(dy)) return dx >= 0 ? 'r' : 'l'
  return dy >= 0 ? 'b' : 't'
}

function portOnSide(
  center: Pt,
  side: Side,
  half: number,
  slot: number,
  slots: number,
): Pt {
  const span = Math.min(ICON - 10, Math.max(0, slots - 1) * PORT_GAP)
  const origin = slots <= 1 ? 0 : -span / 2
  const offset = slots <= 1 ? 0 : origin + slot * (span / Math.max(1, slots - 1))
  switch (side) {
    case 'r':
      return { x: center.x + half, y: center.y + offset }
    case 'l':
      return { x: center.x - half, y: center.y + offset }
    case 'b':
      return { x: center.x + offset, y: center.y + half }
    case 't':
      return { x: center.x + offset, y: center.y - half }
  }
}

function stubFrom(port: Pt, side: Side, dist: number): Pt {
  switch (side) {
    case 'r':
      return { x: port.x + dist, y: port.y }
    case 'l':
      return { x: port.x - dist, y: port.y }
    case 'b':
      return { x: port.x, y: port.y + dist }
    case 't':
      return { x: port.x, y: port.y - dist }
  }
}

function poly(pts: Pt[]): string {
  let d = `M${pts[0].x} ${pts[0].y}`
  for (let i = 1; i < pts.length; i++) d += ` L${pts[i].x} ${pts[i].y}`
  return d
}

function dist(a: Pt, b: Pt): number {
  return Math.hypot(a.x - b.x, a.y - b.y)
}

function isAllowEdge(edge: ArchEdge): boolean {
  return edge.kind === 'allow' || edge.proof.includes('IAM Allow')
}

function allowOutsideSides(fromC: Pt, toC: Pt): { fromSide: Side; toSide: Side } {
  // Vertical-first: leave toward the other row, enter from the side facing source.
  const fromSide: Side =
    Math.abs(toC.y - fromC.y) < 8
      ? facingSide(fromC, toC)
      : toC.y < fromC.y
        ? 't'
        : 'b'
  const toSide: Side =
    Math.abs(toC.y - fromC.y) < 8
      ? facingSide(toC, fromC)
      : toC.x < fromC.x
        ? 'r'
        : toC.x > fromC.x
          ? 'l'
          : facingSide(toC, fromC)
  return { fromSide, toSide }
}

function orthoPorts(
  fromC: Pt,
  toC: Pt,
  fromSide: Side,
  toSide: Side,
  fromSlot: number,
  fromSlots: number,
  toSlot: number,
  toSlots: number,
  verticalFirst: boolean,
): string {
  const fromB = portOnSide(fromC, fromSide, ICON_HALF, fromSlot, fromSlots)
  const toB = portOnSide(toC, toSide, ICON_HALF + ARROW_PAD, toSlot, toSlots)
  const fromS = stubFrom(fromB, fromSide, STUB)
  const toS = stubFrom(toB, toSide, STUB)

  const pts: Pt[] = [fromB, fromS]
  const hFrom = fromSide === 'l' || fromSide === 'r'
  const hTo = toSide === 'l' || toSide === 'r'

  if (Math.abs(fromS.x - toS.x) < 0.5 || Math.abs(fromS.y - toS.y) < 0.5) {
    pts.push(toS)
  } else if (verticalFirst) {
    pts.push({ x: fromS.x, y: toS.y }, toS)
  } else if (hFrom && hTo) {
    const midX = (fromS.x + toS.x) / 2
    pts.push({ x: midX, y: fromS.y }, { x: midX, y: toS.y }, toS)
  } else if (!hFrom && !hTo) {
    const midY = (fromS.y + toS.y) / 2
    pts.push({ x: fromS.x, y: midY }, { x: toS.x, y: midY }, toS)
  } else if (hFrom) {
    pts.push({ x: toS.x, y: fromS.y }, toS)
  } else {
    pts.push({ x: fromS.x, y: toS.y }, toS)
  }

  pts.push(toB)
  return poly(pts)
}

/** Local ortho (same as traffic) — short hops. */
function orthoLocal(
  fromC: Pt,
  toC: Pt,
  fromSlot: number,
  fromSlots: number,
  toSlot: number,
  toSlots: number,
): string {
  return orthoPorts(
    fromC,
    toC,
    facingSide(fromC, toC),
    facingSide(toC, fromC),
    fromSlot,
    fromSlots,
    toSlot,
    toSlots,
    false,
  )
}

export function ArchitectureMapConnectors({
  width,
  height,
  edges,
  positions,
  selectedId,
  activeEdgeIds,
}: {
  width: number
  height: number
  edges: ArchEdge[]
  positions: Map<string, NodePos>
  selectedId: string | null
  activeEdgeIds: Set<string>
}) {
  if (width === 0 || height === 0) return null

  type Prep = {
    edge: ArchEdge
    fromC: Pt
    toC: Pt
    fromSide: Side
    toSide: Side
    route: AllowRoute | 'default'
    active: boolean
  }
  const prepped: Prep[] = []
  for (const edge of edges) {
    const fromC = centerOf(positions.get(edge.from))
    const toC = centerOf(positions.get(edge.to))
    if (!fromC || !toC) continue

    const active = !selectedId || activeEdgeIds.has(edge.id)
    if (selectedId && !active) continue

    if (isAllowEdge(edge) && dist(fromC, toC) > SHORT_ALLOW_PX) {
      const sides = allowOutsideSides(fromC, toC)
      prepped.push({
        edge,
        fromC,
        toC,
        fromSide: sides.fromSide,
        toSide: sides.toSide,
        route: 'outside',
        active,
      })
      continue
    }

    prepped.push({
      edge,
      fromC,
      toC,
      fromSide: facingSide(fromC, toC),
      toSide: facingSide(toC, fromC),
      route: isAllowEdge(edge) ? 'local' : 'default',
      active,
    })
  }

  const outCount = new Map<string, number>()
  const outIndex = new Map<string, number>()
  const inCount = new Map<string, number>()
  const inIndex = new Map<string, number>()
  const outKey = (n: string, s: Side) => `${n}|${s}`
  const inKey = (n: string, s: Side) => `${n}|${s}`

  for (const p of prepped) {
    const ok = outKey(p.edge.from, p.fromSide)
    outCount.set(ok, (outCount.get(ok) ?? 0) + 1)
    const ik = inKey(p.edge.to, p.toSide)
    inCount.set(ik, (inCount.get(ik) ?? 0) + 1)
  }

  prepped.sort((a, b) => {
    if (a.edge.from !== b.edge.from) return a.edge.from.localeCompare(b.edge.from)
    return a.toC.y - b.toC.y || a.toC.x - b.toC.x
  })

  const paths: Array<{ edge: ArchEdge; d: string; active: boolean }> = []
  for (const p of prepped) {
    const ok = outKey(p.edge.from, p.fromSide)
    const ik = inKey(p.edge.to, p.toSide)
    const fromSlot = outIndex.get(ok) ?? 0
    outIndex.set(ok, fromSlot + 1)
    const toSlot = inIndex.get(ik) ?? 0
    inIndex.set(ik, toSlot + 1)

    const d =
      p.route === 'outside'
        ? orthoPorts(
            p.fromC,
            p.toC,
            p.fromSide,
            p.toSide,
            fromSlot,
            outCount.get(ok) ?? 1,
            toSlot,
            inCount.get(ik) ?? 1,
            true,
          )
        : orthoLocal(
            p.fromC,
            p.toC,
            fromSlot,
            outCount.get(ok) ?? 1,
            toSlot,
            inCount.get(ik) ?? 1,
          )

    paths.push({
      edge: p.edge,
      d,
      active: p.active,
    })
  }

  paths.sort((a, b) => Number(a.active) - Number(b.active))

  return (
    <svg
      className="arch-connectors"
      width={width}
      height={height}
      aria-hidden="true"
    >
      <defs>
        <marker
          id="arch-arrow"
          viewBox="0 0 10 10"
          refX="8"
          refY="5"
          markerWidth="6"
          markerHeight="6"
          orient="auto-start-reverse"
        >
          <path d="M0 0 L10 5 L0 10 z" fill="var(--awsbox-quiet)" />
        </marker>
        <marker
          id="arch-arrow-active"
          viewBox="0 0 10 10"
          refX="8"
          refY="5"
          markerWidth="6"
          markerHeight="6"
          orient="auto-start-reverse"
        >
          <path d="M0 0 L10 5 L0 10 z" fill="var(--awsbox-link)" />
        </marker>
      </defs>
      {paths.map(({ edge, d, active }) => (
        <path
          key={edge.id}
          d={d}
          className={`arch-conn arch-conn-${edge.kind}${active ? ' is-active' : ''}`}
          markerEnd={
            active ? 'url(#arch-arrow-active)' : 'url(#arch-arrow)'
          }
        >
          <title>
            {edge.kind}: {edge.proof}
          </title>
        </path>
      ))}
    </svg>
  )
}
