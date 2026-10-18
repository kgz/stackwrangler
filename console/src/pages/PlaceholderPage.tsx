import { Link, useLocation } from 'react-router-dom'

const TITLES: Record<string, { title: string; blurb: string }> = {
  '/directory-buckets': {
    title: 'Directory buckets',
    blurb:
      'Directory buckets (S3 Express One Zone) are not available on the local stack. Use General purpose buckets for v1.',
  },
  '/table-buckets': {
    title: 'Table buckets',
    blurb: 'S3 Tables are not available on the local stack yet.',
  },
  '/vector-buckets': {
    title: 'Vector buckets',
    blurb: 'S3 Vectors are not available on the local stack yet.',
  },
  '/file-systems': {
    title: 'File systems',
    blurb: 'S3 file systems are not available on the local stack yet.',
  },
  '/access-points': {
    title: 'Access Points',
    blurb: 'Access Points land in v2 — not wired to a local API yet.',
  },
  '/access-points-fsx': {
    title: 'Access Points for FSx',
    blurb: 'Not available on the local stack.',
  },
  '/access-grants': {
    title: 'Access Grants',
    blurb: 'Access Grants land in v2 — not wired yet.',
  },
  '/access-analyzer': {
    title: 'IAM Access Analyzer',
    blurb: 'Requires IAM (v1 — IAM track). Not available here yet.',
  },
  '/storage-lens': {
    title: 'Storage Lens',
    blurb: 'Storage Lens lands in v2.',
  },
  '/batch-operations': {
    title: 'Batch Operations',
    blurb: 'Batch Operations land in v2.',
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
