import { useCallback, useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import { describeVpc, listVpcs, type Vpc } from '../lib/ec2'

function VpcList() {
  const [vpcs, setVpcs] = useState<Vpc[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setVpcs(await listVpcs())
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return (
    <>
      <div className="crumbs">
        <span>EC2</span>
        <span className="crumbs-sep">/</span>
        <span>Your VPCs</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">VPCs ({loading ? '…' : vpcs.length})</h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      <p className="page-lead">
        Local VPCs. Display names come from <code>AWSBOX_LABELS</code> (
        <code>docs/labels.md</code>).
      </p>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : vpcs.length === 0 ? (
          <div className="empty">
            <strong>No VPCs</strong>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th>VPC ID</th>
                <th>State</th>
                <th>IPv4 CIDR</th>
                <th>Default</th>
              </tr>
            </thead>
            <tbody>
              {vpcs.map((vpc) => {
                const id = vpc.VpcId ?? ''
                return (
                  <tr key={id}>
                    <td>
                      <ResourceLabel ids={[id]}>
                        <Link to={`/ec2/vpcs/${encodeURIComponent(id)}`}>
                          {id || '—'}
                        </Link>
                      </ResourceLabel>
                    </td>
                    <td>{vpc.State ?? '—'}</td>
                    <td className="cfn-muted">{vpc.CidrBlock ?? '—'}</td>
                    <td className="cfn-muted">{vpc.IsDefault ? 'Yes' : 'No'}</td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}

function VpcDetail({ vpcId }: { vpcId: string }) {
  const [vpc, setVpc] = useState<Vpc | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeVpc(vpcId)
      if (!found) throw new Error(`VPC ${vpcId} not found`)
      setVpc(found)
    } catch (err) {
      setVpc(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [vpcId])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return (
    <>
      <div className="crumbs">
        <Link to="/ec2">EC2</Link>
        <span className="crumbs-sep">/</span>
        <Link to="/ec2/vpcs">Your VPCs</Link>
        <span className="crumbs-sep">/</span>
        <span>{vpcId}</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">{vpcId}</h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel cfn-overview">
        {loading || !vpc ? (
          <div className="cfn-loading">Loading…</div>
        ) : (
          <section>
            <h2 className="cfn-section-title">Overview</h2>
            <dl className="cfn-kv">
              <div>
                <dt>VPC ID</dt>
                <dd>
                  <ResourceLabel ids={[vpc.VpcId]} detail>
                    <code>{vpc.VpcId ?? '—'}</code>
                  </ResourceLabel>
                </dd>
              </div>
              <div>
                <dt>State</dt>
                <dd>{vpc.State ?? '—'}</dd>
              </div>
              <div>
                <dt>IPv4 CIDR</dt>
                <dd>{vpc.CidrBlock ?? '—'}</dd>
              </div>
              <div>
                <dt>Default</dt>
                <dd>{vpc.IsDefault ? 'Yes' : 'No'}</dd>
              </div>
            </dl>
          </section>
        )}
      </div>
    </>
  )
}

export function VpcsPage() {
  const { vpcId } = useParams()
  if (vpcId) return <VpcDetail vpcId={decodeURIComponent(vpcId)} />
  return <VpcList />
}
