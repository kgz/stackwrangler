import { Link, useLocation } from 'react-router-dom'

type Kind = 'directory' | 'table' | 'vector'

const META: Record<
  Kind,
  { title: string; heading: string; empty: string; createLabel: string }
> = {
  directory: {
    title: 'Directory buckets',
    heading: 'Directory buckets (0)',
    empty:
      'Directory buckets (S3 Express One Zone) are not available on this local stack. Use General purpose buckets.',
    createLabel: 'Create directory bucket',
  },
  table: {
    title: 'Table buckets',
    heading: 'Table buckets (0)',
    empty:
      'S3 Tables are not available on this local stack. Use General purpose buckets.',
    createLabel: 'Create table bucket',
  },
  vector: {
    title: 'Vector buckets',
    heading: 'Vector buckets (0)',
    empty:
      'S3 Vectors are not available on this local stack. Use General purpose buckets.',
    createLabel: 'Create vector bucket',
  },
}

function kindFromPath(pathname: string): Kind {
  if (pathname.includes('table')) return 'table'
  if (pathname.includes('vector')) return 'vector'
  return 'directory'
}

export function SpecialtyBucketsPage() {
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

        <div className="empty" data-testid={`${kind}-buckets-empty`}>
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
