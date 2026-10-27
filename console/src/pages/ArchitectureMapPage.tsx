import {
  useCallback,
  useEffect,
  useMemo,
  useState,
  type CSSProperties,
} from 'react'
import { Link } from 'react-router-dom'
import { TransformComponent, TransformWrapper } from 'react-zoom-pan-pinch'
import { Notices, Mono, StatusBadge } from '../components/ServiceUi'
import { RefreshButton } from '../components/S3Ui'
import {
  fetchAccountTopology,
  listTenantsFromNodes,
  type AccountTopology,
  type ArchEdge,
  type ArchLayer,
  type ArchNode,
} from '../lib/topology'
import {
  EMPTY_LAYOUT,
  edgesForMindMap,
  layoutArchitectureMap,
  type MapLayout,
} from '../lib/architectureMapLayout'
import { ArchitectureMapConnectors } from './ArchitectureMapConnectors'
import './ArchitectureMapPage.css'

const LAYERS: Array<{ id: ArchLayer; label: string }> = [
  { id: 'edge', label: 'Edge' },
  { id: 'networking', label: 'Networking' },
  { id: 'compute', label: 'Compute' },
  { id: 'data', label: 'Data' },
  { id: 'messaging', label: 'Messaging' },
  { id: 'identity', label: 'Identity' },
]

const POLL_MS = 8000

function kindCaption(kind: ArchNode['kind']): string {
  switch (kind) {
    case 'users':
      return 'Internet'
    case 's3':
      return 'S3'
    case 'vpc':
      return 'VPC'
    case 'igw':
      return 'IGW'
    case 'nat':
      return 'NAT'
    case 'alb':
      return 'ALB'
    case 'ec2':
      return 'EC2'
    case 'ecs-cluster':
      return 'ECS'
    case 'rds':
      return 'RDS'
    case 'sqs':
      return 'SQS'
    case 'iam-role':
      return 'IAM role'
    case 'iam-user':
      return 'IAM user'
    case 'lambda':
      return 'Lambda'
    case 'route53':
      return 'Route 53'
    case 'asg':
      return 'ASG'
    case 'iam-allows':
      return 'Allows'
    default:
      return kind
  }
}

function NodeIcon({ kind }: { kind: ArchNode['kind'] }) {
  const common = {
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.6,
    'aria-hidden': true as const,
  }
  switch (kind) {
    case 'users':
      return (
        <svg {...common}>
          <circle cx="9" cy="8" r="2.5" />
          <circle cx="15" cy="8" r="2.5" />
          <path d="M4.5 18c.5-2.5 2.4-4 4.5-4s4 1.5 4.5 4" />
          <path d="M10.5 18c.5-2.5 2.4-4 4.5-4s4 1.5 4.5 4" />
        </svg>
      )
    case 's3':
      return (
        <svg {...common}>
          <path d="M4 8l8-3 8 3v8l-8 3-8-3V8z" />
          <path d="M4 8l8 3 8-3M12 11v9" />
        </svg>
      )
    case 'igw':
      return (
        <svg {...common}>
          <path d="M4 14c2-4 5-6 8-6s6 2 8 6" />
          <path d="M12 8V4M9 5l3-2 3 2" />
          <circle cx="12" cy="16" r="2" />
        </svg>
      )
    case 'nat':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="8" />
          <path d="M12 8v8M9 11l3-3 3 3M9 14l3 3 3-3" />
        </svg>
      )
    case 'alb':
      return (
        <svg {...common}>
          <path d="M12 4v4M12 16v4" />
          <circle cx="12" cy="12" r="3" />
          <path d="M5 8l7 4 7-4M5 16l7-4 7 4" />
        </svg>
      )
    case 'ec2':
      return (
        <svg {...common}>
          <rect x="5" y="4" width="14" height="16" rx="1.5" />
          <path d="M8 8h8M8 12h8M8 16h5" />
        </svg>
      )
    case 'ecs-cluster':
      return (
        <svg {...common}>
          <path d="M12 3l8 4.5v9L12 21l-8-4.5v-9L12 3z" />
          <path d="M12 12l8-4.5M12 12v9M12 12L4 7.5" />
        </svg>
      )
    case 'rds':
      return (
        <svg {...common}>
          <ellipse cx="12" cy="7" rx="7" ry="3" />
          <path d="M5 7v5c0 1.7 3.1 3 7 3s7-1.3 7-3V7" />
          <path d="M5 12v5c0 1.7 3.1 3 7 3s7-1.3 7-3v-5" />
        </svg>
      )
    case 'sqs':
      return (
        <svg {...common}>
          <rect x="3" y="6" width="18" height="12" rx="2" />
          <path d="M7 10h10M7 14h6" />
        </svg>
      )
    case 'iam-role':
      return (
        <svg {...common}>
          <circle cx="12" cy="10" r="3.5" />
          <path d="M12 13.5V20M12 20l-2.5 2M12 20l2.5 2M12 17h2.5" />
          <circle cx="12" cy="10" r="1.2" fill="currentColor" stroke="none" />
        </svg>
      )
    case 'iam-user':
      return (
        <svg {...common}>
          <circle cx="12" cy="8" r="3" />
          <path d="M6 19c1.5-3 3.5-4.5 6-4.5S16.5 16 18 19" />
        </svg>
      )
    case 'lambda':
      return (
        <svg {...common}>
          <path d="M8 4h5l5 16h-5L8 4z" />
          <path d="M7 12h6" />
        </svg>
      )
    case 'route53':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="8" />
          <path d="M12 4v16M4 12h16" />
          <path d="M6 8c2 1 4 1.5 6 1.5S16 9 18 8M6 16c2-1 4-1.5 6-1.5S16 15 18 16" />
        </svg>
      )
    case 'asg':
      return (
        <svg {...common}>
          <rect x="2" y="5" width="7" height="10" rx="1" />
          <rect x="9.5" y="3" width="5" height="14" rx="1" />
          <rect x="15" y="5" width="7" height="10" rx="1" />
        </svg>
      )
    case 'iam-allows':
      return (
        <svg {...common}>
          <rect x="4" y="5" width="16" height="14" rx="2" />
          <path d="M8 10h8M8 14h5" />
          <circle cx="17" cy="7" r="2.5" />
        </svg>
      )
    default:
      return (
        <svg {...common}>
          <rect x="5" y="5" width="14" height="14" rx="2" />
        </svg>
      )
  }
}

function ArchNodeButton({
  node,
  selected,
  related,
  onSelect,
  allowCount,
  style,
}: {
  node: ArchNode
  selected: boolean
  related: boolean
  onSelect: (id: string) => void
  allowCount?: number
  style?: CSSProperties
}) {
  const iamMid = node.kind === 'iam-role'
  return (
    <button
      type="button"
      className={`arch-node${selected ? ' is-selected' : ''}${related && !selected ? ' is-related' : ''}${iamMid ? ' is-iam-mid' : ''}`}
      data-node={node.id}
      data-kind={node.kind}
      data-layer={node.layer}
      style={style}
      onClick={() => onSelect(node.id)}
    >
      <span className="arch-node-icon" aria-hidden="true">
        <NodeIcon kind={node.kind} />
        {allowCount !== undefined && allowCount > 0 ? (
          <span className="arch-allow-badge" title={`${allowCount} identity Allows`}>
            {allowCount}
          </span>
        ) : null}
      </span>
      <span className="arch-node-kind">{kindCaption(node.kind)}</span>
      <span className="arch-node-label">{node.label}</span>
      {node.status ? (
        <span className="arch-node-status">
          <StatusBadge status={node.status} />
        </span>
      ) : null}
    </button>
  )
}

function edgesForNode(edges: ArchEdge[], id: string): ArchEdge[] {
  return edges.filter((e) => e.from === id || e.to === id)
}

export function ArchitectureMapPage() {
  const [topo, setTopo] = useState<AccountTopology | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [showLinks, setShowLinks] = useState(true)
  const [showStaff, setShowStaff] = useState(false)
  const [tenantFilter, setTenantFilter] = useState<string>('all')
  const [layers, setLayers] = useState<Record<ArchLayer, boolean>>({
    edge: true,
    networking: true,
    compute: true,
    data: true,
    messaging: true,
    identity: true,
  })
  const [live, setLive] = useState(true)

  const refresh = useCallback(async () => {
    setError(null)
    try {
      const next = await fetchAccountTopology()
      setTopo(next)
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  useEffect(() => {
    if (!live) return
    const id = window.setInterval(() => {
      void refresh()
    }, POLL_MS)
    return () => window.clearInterval(id)
  }, [live, refresh])

  const nodes = topo?.nodes ?? []
  const edges = topo?.edges ?? []
  const gaps = useMemo(() => {
    const all = topo?.gaps ?? []
    if (tenantFilter === 'all') return all
    const needle = tenantFilter.replace(/^t/, '')
    return all.filter((g) => {
      if (g.id.includes('gap-sg') || g.id.includes('gap-resource')) return true
      return (
        g.id.includes(tenantFilter) ||
        g.label.includes(tenantFilter) ||
        g.detail.includes(tenantFilter) ||
        g.id.includes(`tenant-${needle}`) ||
        g.label.includes(`tenant-${needle}`)
      )
    })
  }, [topo?.gaps, tenantFilter])
  const selected = nodes.find((n) => n.id === selectedId) ?? null

  const tenants = useMemo(() => listTenantsFromNodes(nodes), [nodes])

  const visible = useMemo(() => {
    return nodes.filter((n) => {
      // Hubs are collapsed onto roles — IAM sits mid-edge on the canvas
      if (n.kind === 'iam-allows') return false
      if (n.kind === 'vpc') return false
      if (n.kind === 'iam-user' && !showStaff) return false
      if (tenantFilter !== 'all' && n.kind !== 'users') {
        if (n.tenant && n.tenant !== tenantFilter) return false
        if (!n.tenant) return false
      }
      return layers[n.layer]
    })
  }, [nodes, layers, tenantFilter, showStaff])

  const mindEdges = useMemo(
    () => edgesForMindMap(edges, nodes),
    [edges, nodes],
  )

  const layoutEdges = useMemo(() => {
    const ids = new Set(visible.map((n) => n.id))
    ids.add('users')
    return mindEdges.filter((e) => ids.has(e.from) && ids.has(e.to))
  }, [mindEdges, visible])

  const visibleEdges = useMemo(() => {
    if (!showLinks) return []
    return layoutEdges
  }, [layoutEdges, showLinks])

  /** Incident edges + everything reachable following from→to from the selection. */
  const flowEdgeIds = useMemo(() => {
    const s = new Set<string>()
    if (!selectedId) return s
    for (const e of layoutEdges) {
      if (e.from === selectedId || e.to === selectedId) s.add(e.id)
    }
    const outbound = new Map<string, ArchEdge[]>()
    for (const e of layoutEdges) {
      const list = outbound.get(e.from) ?? []
      list.push(e)
      outbound.set(e.from, list)
    }
    const queue = [selectedId]
    const seen = new Set<string>([selectedId])
    while (queue.length > 0) {
      const cur = queue.shift()
      if (!cur) break
      for (const e of outbound.get(cur) ?? []) {
        s.add(e.id)
        if (!seen.has(e.to)) {
          seen.add(e.to)
          queue.push(e.to)
        }
      }
    }
    return s
  }, [layoutEdges, selectedId])

  const selectedEdges = selectedId
    ? edgesForNode(visibleEdges, selectedId)
    : []

  const allowByRole = useMemo(() => {
    const m = new Map<string, ArchNode>()
    for (const n of nodes) {
      if (n.kind === 'iam-allows' && n.roleId) m.set(n.roleId, n)
    }
    return m
  }, [nodes])

  const relatedIds = useMemo(() => {
    const s = new Set<string>()
    if (!selectedId) return s
    for (const e of layoutEdges) {
      if (!flowEdgeIds.has(e.id)) continue
      s.add(e.from)
      s.add(e.to)
    }
    s.delete(selectedId)
    const hub = allowByRole.get(selectedId)
    if (hub?.allowBreakdown) {
      for (const b of hub.allowBreakdown) s.add(b.targetId)
    }
    return s
  }, [layoutEdges, selectedId, flowEdgeIds, allowByRole])

  const layoutVpc =
    nodes.find(
      (n) =>
        n.kind === 'vpc' &&
        (n.label.toLowerCase().includes('arch-map') ||
          n.meta.some((m) => m.label === 'Default' && m.value === 'no')),
    ) ?? nodes.find((n) => n.kind === 'vpc')

  const vpcLabel = layoutVpc?.label ?? 'VPC'

  const [mapLayout, setMapLayout] = useState<MapLayout>(EMPTY_LAYOUT)

  useEffect(() => {
    let cancelled = false
    void layoutArchitectureMap(visible, layoutEdges, vpcLabel).then(
      (next) => {
        if (!cancelled) setMapLayout(next)
      },
    )
    return () => {
      cancelled = true
    }
  }, [visible, layoutEdges, vpcLabel])

  function toggleLayer(id: ArchLayer) {
    setLayers((cur) => ({ ...cur, [id]: !cur[id] }))
  }

  function onSelect(id: string) {
    setSelectedId((cur) => (cur === id ? null : id))
  }

  const sheetOpen = Boolean(selected)

  function nodeLabel(id: string): string {
    return nodes.find((n) => n.id === id)?.label ?? id
  }

  return (
    <div className="arch-page" data-testid="architecture-map">
      <h1 className="aws-h1">Architecture map</h1>
      <p className="aws-desc">
        Honest overview of what this local account actually wires — attachments,
        routes, load-balancer targets, task roles, and IAM <code>Allow</code>s —
        including extra accesses a hand-drawn diagram usually omits. Review
        before shipping.         Lab seed: <code>./bin/architecture-map-seed.sh</code>. Org CRM scale:{' '}
        <code>./bin/architecture-map-org-seed.sh</code> (see{' '}
        <code>docs/architecture-map-org.md</code>).
      </p>

      <Notices error={error} />

      <div className="arch-toolbar-row">
        <button
          type="button"
          className="arch-live"
          data-state={live ? 'live' : 'paused'}
          onClick={() => setLive((v) => !v)}
          title={
            live ? 'Polling every 8s — click to pause' : 'Paused — click to resume'
          }
        >
          <span className="arch-live-dot" aria-hidden="true" />
          <span>{live ? 'Live' : 'Paused'}</span>
        </button>

        <fieldset className="arch-toggles">
          <legend>Layers</legend>
          {LAYERS.map((layer) => (
            <label
              key={layer.id}
              className="arch-toggle"
              aria-pressed={layers[layer.id]}
            >
              <input
                type="checkbox"
                checked={layers[layer.id]}
                onChange={() => toggleLayer(layer.id)}
              />
              {layer.label}
            </label>
          ))}
          <label className="arch-toggle" aria-pressed={showLinks}>
            <input
              type="checkbox"
              checked={showLinks}
              onChange={() => setShowLinks((v) => !v)}
            />
            Links
          </label>
          <label className="arch-toggle" aria-pressed={showStaff}>
            <input
              type="checkbox"
              checked={showStaff}
              onChange={() => setShowStaff((v) => !v)}
            />
            Staff users
          </label>
        </fieldset>

        <label className="arch-tenant-filter">
          <span>Tenant</span>
          <select
            value={tenantFilter}
            onChange={(e) => {
              setTenantFilter(e.target.value)
              setSelectedId(null)
            }}
            aria-label="Filter by tenant"
          >
            <option value="all">All ({tenants.length || 0})</option>
            {tenants.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </label>

        <div className="spacer" style={{ flex: 1 }} />

        <span className="arch-meta">
          {loading && !topo
            ? 'Loading…'
            : topo
              ? `Updated ${new Date(topo.fetchedAt).toLocaleTimeString()}`
              : null}
        </span>
        <RefreshButton onClick={() => void refresh()} />
      </div>

      <div className="arch-legend" aria-label="Link legend">
        <span>
          <i /> attach / traffic
        </span>
        <span>
          <i className="lg-route" /> route
        </span>
        <span>
          <i className="lg-identity" /> identity (compute → IAM)
        </span>
        <span>
          <i className="lg-allow" /> IAM Allow — all joins shown; click a node
          to highlight its flow
        </span>
      </div>

      {gaps.length > 0 ? (
        <details className="arch-gaps">
          <summary>
            Honesty gaps ({gaps.length}) — paths we will not invent
          </summary>
          <ul>
            {gaps.map((g) => (
              <li key={g.id}>
                <strong>{g.label}</strong>
                <div className="gap-detail">{g.detail}</div>
              </li>
            ))}
          </ul>
        </details>
      ) : null}

      <div className={`arch-stage${sheetOpen ? ' is-open' : ''}`}>
        <div className="arch-canvas-wrap">
          <TransformWrapper
            key={`${tenantFilter}|${mapLayout.width}x${mapLayout.height}`}
            minScale={0.2}
            maxScale={2.5}
            initialScale={1}
            centerOnInit
            limitToBounds={false}
            // smooth=true multiplies step × |deltaY| (trackpads send huge deltas)
            smooth={false}
            wheel={{ step: 0.035 }}
            pinch={{ step: 2 }}
            doubleClick={{ mode: 'zoomIn', step: 0.05 }}
            panning={{
              excluded: ['arch-node', 'arch-zoom-controls'],
            }}
            keyboard={{ disabled: false, panStep: 48, zoomStep: 0.01 }}
          >
            {(controls) => (
              <>
                <div className="arch-zoom-controls" role="toolbar" aria-label="Map zoom">
                  <button
                    type="button"
                    className="arch-zoom-btn"
                    title="Zoom in"
                    onClick={() => void controls.zoomIn(0.08)}
                  >
                    +
                  </button>
                  <button
                    type="button"
                    className="arch-zoom-btn"
                    title="Zoom out"
                    onClick={() => void controls.zoomOut(0.08)}
                  >
                    −
                  </button>
                  <button
                    type="button"
                    className="arch-zoom-btn"
                    title="Reset view"
                    onClick={() => void controls.resetTransform()}
                  >
                    ⟲
                  </button>
                  <button
                    type="button"
                    className="arch-zoom-btn"
                    title="Fit to view"
                    onClick={() => void controls.fitToView()}
                  >
                    fit
                  </button>
                  <span className="arch-zoom-hint">
                    drag to pan · scroll to zoom · arrows to nudge
                  </span>
                </div>
                <TransformComponent
                  wrapperClass="arch-pan-wrapper"
                  contentClass="arch-pan-content"
                >
                  <div
                    className="arch-canvas"
                    style={{
                      width: mapLayout.width,
                      height: mapLayout.height,
                    }}
                  >
                    {mapLayout.hull ? (
                      <>
                        <div
                          className="arch-vpc-hull"
                          style={{
                            left: mapLayout.hull.x,
                            top: mapLayout.hull.y,
                            width: mapLayout.hull.w,
                            height: mapLayout.hull.h,
                          }}
                        />
                        <span
                          className="arch-vpc-hull-label"
                          style={{
                            left: mapLayout.hull.x + 8,
                            top: mapLayout.hull.y + 2,
                          }}
                        >
                          {mapLayout.hull.label}
                        </span>
                      </>
                    ) : null}
                    {showLinks ? (
                      <ArchitectureMapConnectors
                        width={mapLayout.width}
                        height={mapLayout.height}
                        edges={visibleEdges}
                        positions={mapLayout.positions}
                        selectedId={selectedId}
                        activeEdgeIds={flowEdgeIds}
                      />
                    ) : null}
                    {visible.map((n) => {
                      const pos = mapLayout.positions.get(n.id)
                      if (!pos) return null
                      const hub = allowByRole.get(n.id)
                      return (
                        <ArchNodeButton
                          key={n.id}
                          node={n}
                          selected={selectedId === n.id}
                          related={relatedIds.has(n.id)}
                          onSelect={onSelect}
                          allowCount={hub?.allowBreakdown?.length}
                          style={{
                            position: 'absolute',
                            left: pos.x,
                            top: pos.y,
                          }}
                        />
                      )
                    })}
                  </div>
                </TransformComponent>
                <p className="arch-caption">
                  {topo
                    ? `${visible.length} on map · ${visibleEdges.length} links · ${gaps.length} gaps · ${topo.vpcs.length} VPC · ${topo.clusters.length} ECS · ${topo.databases.length} RDS · ${topo.queues.length} SQS`
                    : 'Waiting for topology…'}
                </p>
              </>
            )}
          </TransformWrapper>
        </div>

        <aside className="arch-sheet" aria-label="Resource detail">
          <div className="arch-sheet-head">
            <div>
              <h2>{selected?.label ?? 'Select a resource'}</h2>
              <p className="arch-sheet-type">
                {selected
                  ? (selected.meta.find((m) => m.label === 'Type')?.value ??
                    selected.kind)
                  : 'Click a node — linked edges highlight'}
              </p>
            </div>
            <button
              type="button"
              className="btn-icon"
              aria-label="Close"
              onClick={() => setSelectedId(null)}
            >
              ×
            </button>
          </div>
          <div className="arch-sheet-body">
            {selected ? (
              <>
                <div className="aws-kv">
                  {selected.meta.map((row) => (
                    <div key={row.label}>
                      <dt>{row.label}</dt>
                      <dd>
                        {row.label === 'ARN' ||
                        row.label === 'URL' ||
                        row.label === 'VPC ID' ||
                        row.label === 'ID' ||
                        row.label === 'VPC' ? (
                          <Mono>{row.value}</Mono>
                        ) : (
                          row.value
                        )}
                      </dd>
                    </div>
                  ))}
                </div>

                {selected.kind === 'iam-role' &&
                allowByRole.get(selected.id)?.allowBreakdown ? (
                  <div>
                    <h3
                      className="aws-h3"
                      style={{ fontSize: 13, margin: '0 0 8px' }}
                    >
                      Allow breakdown (
                      {allowByRole.get(selected.id)?.allowBreakdown?.length})
                    </h3>
                    <p className="arch-placeholder" style={{ marginBottom: 8 }}>
                      Nearby Allows draw as gold joins; far ones (e.g. across
                      the VPC) stay in this list + the badge only for now.
                    </p>
                    <div className="arch-edge-list">
                      {allowByRole
                        .get(selected.id)
                        ?.allowBreakdown?.map((b) => (
                          <button
                            key={`${b.targetId}:${b.service}`}
                            type="button"
                            className="edge-row edge-row-btn"
                            onClick={() => setSelectedId(b.targetId)}
                          >
                            <div className="edge-kind">{b.service}</div>
                            <div>{b.targetLabel}</div>
                            <div className="gap-detail">{b.proof}</div>
                          </button>
                        ))}
                    </div>
                  </div>
                ) : (
                  <div>
                    <h3
                      className="aws-h3"
                      style={{ fontSize: 13, margin: '0 0 8px' }}
                    >
                      Proven links ({selectedEdges.length})
                    </h3>
                    {selectedEdges.length === 0 ? (
                      <p className="arch-placeholder">
                        No proven edges for this node yet.
                      </p>
                    ) : (
                      <div className="arch-edge-list">
                        {selectedEdges.map((e) => {
                          const other =
                            e.from === selected.id ? e.to : e.from
                          const dir = e.from === selected.id ? '→' : '←'
                          return (
                            <div key={e.id} className="edge-row">
                              <div className="edge-kind">{e.kind}</div>
                              <div>
                                {dir} {nodeLabel(other)}
                              </div>
                              <div className="gap-detail">{e.proof}</div>
                            </div>
                          )
                        })}
                      </div>
                    )}
                  </div>
                )}

                <div className="arch-sheet-actions">
                  {selected.href ? (
                    <Link className="btn btn-primary" to={selected.href}>
                      Open in console
                    </Link>
                  ) : (
                    <button
                      type="button"
                      className="btn btn-primary"
                      disabled
                      aria-disabled="true"
                      title="To implement"
                    >
                      Open in console
                    </button>
                  )}
                </div>
              </>
            ) : (
              <p className="arch-placeholder">No resource selected.</p>
            )}
          </div>
        </aside>
      </div>
    </div>
  )
}
