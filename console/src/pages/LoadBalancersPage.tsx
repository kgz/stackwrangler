import { useCallback, useEffect, useState } from 'react'
import { Link, useSearchParams } from 'react-router-dom'
import { ResourceLabel } from '../components/ResourceLabel'
import {
  describeLoadBalancer,
  listLoadBalancers,
  type LoadBalancer,
} from '../lib/elbv2'

function lbPath(arn: string): string {
  return `/ec2/load-balancers?arn=${encodeURIComponent(arn)}`
}

function LoadBalancerList() {
  const [lbs, setLbs] = useState<LoadBalancer[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setLbs(await listLoadBalancers())
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
        <span>Load balancers</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          Load balancers ({loading ? '…' : lbs.length})
        </h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      <p className="page-lead">
        Local load balancers. Display names come from <code>AWSBOX_LABELS</code>{' '}
        (<code>docs/labels.md</code>).
      </p>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : lbs.length === 0 ? (
          <div className="empty">
            <strong>No load balancers</strong>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th>Name</th>
                <th>State</th>
                <th>Type</th>
                <th>Scheme</th>
                <th>DNS name</th>
              </tr>
            </thead>
            <tbody>
              {lbs.map((lb) => {
                const arn = lb.LoadBalancerArn ?? ''
                const name = lb.LoadBalancerName ?? arn
                return (
                  <tr key={arn || name}>
                    <td>
                      <ResourceLabel ids={[arn, name]}>
                        <Link to={arn ? lbPath(arn) : '/ec2/load-balancers'}>
                          {name || '—'}
                        </Link>
                      </ResourceLabel>
                    </td>
                    <td>{lb.State?.Code ?? '—'}</td>
                    <td className="cfn-muted">{lb.Type ?? '—'}</td>
                    <td className="cfn-muted">{lb.Scheme ?? '—'}</td>
                    <td className="cfn-muted">{lb.DNSName ?? '—'}</td>
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

function LoadBalancerDetail({ arn }: { arn: string }) {
  const [lb, setLb] = useState<LoadBalancer | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      const found = await describeLoadBalancer(arn)
      if (!found) throw new Error('Load balancer not found')
      setLb(found)
    } catch (err) {
      setLb(null)
      setError(err instanceof Error ? err.message : String(err))
    } finally {
      setLoading(false)
    }
  }, [arn])

  useEffect(() => {
    void refresh()
  }, [refresh])

  const name = lb?.LoadBalancerName ?? arn

  return (
    <>
      <div className="crumbs">
        <Link to="/ec2">EC2</Link>
        <span className="crumbs-sep">/</span>
        <Link to="/ec2/load-balancers">Load balancers</Link>
        <span className="crumbs-sep">/</span>
        <span>{name}</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">{name}</h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel cfn-overview">
        {loading || !lb ? (
          <div className="cfn-loading">Loading…</div>
        ) : (
          <section>
            <h2 className="cfn-section-title">Overview</h2>
            <dl className="cfn-kv">
              <div>
                <dt>ARN</dt>
                <dd>
                  <ResourceLabel ids={[lb.LoadBalancerArn]} detail>
                    <code className="cfn-arn">{lb.LoadBalancerArn ?? '—'}</code>
                  </ResourceLabel>
                </dd>
              </div>
              <div>
                <dt>DNS name</dt>
                <dd>{lb.DNSName ?? '—'}</dd>
              </div>
              <div>
                <dt>State</dt>
                <dd>{lb.State?.Code ?? '—'}</dd>
              </div>
              <div>
                <dt>Type</dt>
                <dd>{lb.Type ?? '—'}</dd>
              </div>
              <div>
                <dt>Scheme</dt>
                <dd>{lb.Scheme ?? '—'}</dd>
              </div>
            </dl>
          </section>
        )}
      </div>
    </>
  )
}

export function LoadBalancersPage() {
  const [params] = useSearchParams()
  const arn = params.get('arn')
  if (arn) return <LoadBalancerDetail arn={arn} />
  return <LoadBalancerList />
}
