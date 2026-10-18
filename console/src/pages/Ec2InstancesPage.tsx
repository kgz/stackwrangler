import { useCallback, useEffect, useState } from 'react'
import { listInstances, type Instance } from '../lib/ec2'

function nameTag(i: Instance): string {
  const tag = (i.Tags ?? []).find((t) => t.Key === 'Name')
  return tag?.Value ?? '—'
}

export function Ec2InstancesPage() {
  const [instances, setInstances] = useState<Instance[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  const refresh = useCallback(async () => {
    setLoading(true)
    setError(null)
    try {
      setInstances(await listInstances())
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
        <span>Instances</span>
      </div>
      <div className="cfn-page-head">
        <h1 className="page-title">
          Instances ({loading ? '…' : instances.length})
        </h1>
        <button type="button" className="btn" onClick={() => void refresh()}>
          Refresh
        </button>
      </div>
      <p className="page-lead">
        Docker-backed via LocalEmu. Create with <code>./bin/ec2-smoke.sh</code>.
      </p>
      {error ? <div className="error-banner">{error}</div> : null}
      <div className="panel">
        {loading ? (
          <div className="cfn-loading">Loading…</div>
        ) : instances.length === 0 ? (
          <div className="empty">
            <strong>No instances</strong>
          </div>
        ) : (
          <table className="data">
            <thead>
              <tr>
                <th>Instance ID</th>
                <th>Name</th>
                <th>State</th>
                <th>Type</th>
                <th>Private IP</th>
                <th>AZ</th>
              </tr>
            </thead>
            <tbody>
              {instances.map((i) => (
                <tr key={i.InstanceId}>
                  <td>
                    <code>{i.InstanceId ?? '—'}</code>
                  </td>
                  <td>{nameTag(i)}</td>
                  <td>{i.State?.Name ?? '—'}</td>
                  <td className="cfn-muted">{i.InstanceType ?? '—'}</td>
                  <td className="cfn-muted">{i.PrivateIpAddress ?? '—'}</td>
                  <td className="cfn-muted">
                    {i.Placement?.AvailabilityZone ?? '—'}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}
