import { Link, useLocation } from 'react-router-dom'

const TITLES: Record<string, { title: string; blurb: string }> = {
  '/file-systems': {
    title: 'File systems',
    blurb: 'S3 file systems are not available on the local stack yet.',
  },
  '/access-analyzer': {
    title: 'IAM Access Analyzer',
    blurb: 'Requires IAM (v1 — IAM track). Not available here yet.',
  },
  '/account-settings': {
    title: 'Account and organization settings',
    blurb: 'Local account chrome only — no org APIs yet.',
  },
  '/marketplace': {
    title: 'AWS Marketplace for S3',
    blurb: 'Not applicable on the local stack.',
  },
}

export function PlaceholderPage() {
  const { pathname } = useLocation()
  const meta = TITLES[pathname] ?? {
    title: 'Not available',
    blurb: 'This console page is not implemented on the local stack yet.',
  }

  return (
    <>
      <div className="crumbs">
        <Link to="/">Amazon S3</Link> &gt; {meta.title}
      </div>
      <h1 className="page-title">{meta.title}</h1>
      <div className="panel">
        <div className="empty">
          <strong>Not available on local stack</strong>
          {meta.blurb}
          <div style={{ marginTop: 16 }}>
            <Link to="/">Go to General purpose buckets</Link>
          </div>
        </div>
      </div>
    </>
  )
}
