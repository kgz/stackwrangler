import { Link, useLocation } from 'react-router-dom'

type Kind = 'access-points' | 'access-points-fsx' | 'access-grants'

const META: Record<
  Kind,
  { title: string; heading: string; empty: string; createLabel: string }
> = {
  'access-points': {
    title: 'Access Points',
    heading: 'Access Points (0)',
    empty:
      'S3 Access Points are not available on this local stack. General purpose buckets work without them.',
    createLabel: 'Create access point',
  },
  'access-points-fsx': {
    title: 'Access Points for FSx',
    heading: 'Access Points for FSx (0)',
    empty: 'Access Points for FSx are not available on this local stack.',
    createLabel: 'Create access point',
  },
  'access-grants': {
    title: 'Access Grants',
    heading: 'Access Grants (0)',
    empty: 'S3 Access Grants are not available on this local stack.',
    createLabel: 'Create grant',
  },
}

function kindFromPath(pathname: string): Kind {
  if (pathname.includes('fsx')) return 'access-points-fsx'
  if (pathname.includes('grants')) return 'access-grants'
  return 'access-points'
}

export function AccessManagementPage() {
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
