import { Link, useLocation } from 'react-router-dom'

type Kind = 'storage-lens' | 'batch-operations'

const META: Record<
  Kind,
  { title: string; heading: string; empty: string; createLabel: string }
> = {
  'storage-lens': {
    title: 'Storage Lens',
    heading: 'Storage Lens dashboards (0)',
    empty:
      'S3 Storage Lens is not available on this local stack. Use CLI and console object listings for local data.',
    createLabel: 'Create dashboard',
  },
  'batch-operations': {
    title: 'Batch Operations',
    heading: 'Batch Operations jobs (0)',
    empty: 'S3 Batch Operations are not available on this local stack.',
    createLabel: 'Create job',
  },
}

function kindFromPath(pathname: string): Kind {
  if (pathname.includes('batch')) return 'batch-operations'
  return 'storage-lens'
}

export function StorageInsightsPage() {
  const { pathname } = useLocation()
  const kind = kindFromPath(pathname)
  const meta = META[kind]

  return (
    <>
      <div className="crumbs">
        <Link to="/">Amazon S3</Link> &gt; {meta.title}
      </div>
      <h1 className="page-title">{meta.title}</h1>

      <div className="panel">
        <div className="toolbar">
          <h3>{meta.heading}</h3>
          <button type="button" className="btn" disabled title="Not supported locally">
            Refresh
          </button>
          <button
            type="button"
            className="btn btn-primary"
            disabled
            title="Not supported on local stack"
          >
            {meta.createLabel}
          </button>
        </div>

        <div className="empty" data-testid={`${kind}-empty`}>
          <strong>Not available on local stack</strong>
          {meta.empty}
          <div style={{ marginTop: 16 }}>
            <Link to="/">Go to General purpose buckets</Link>
          </div>
        </div>
      </div>
    </>
  )
}
