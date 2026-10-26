import { useEffect } from 'react'
import { useLocation } from 'react-router-dom'

const ROWS = [
  { id: 'storage-backup', title: 'Storage, Back-up and Recovery products for S3' },
  { id: 'data-integration', title: 'Data Integration and Analytics products for S3' },
  { id: 'observability', title: 'Observability and Monitoring products for S3' },
  { id: 'security', title: 'Security and Threat Detection products for S3' },
  { id: 'permissions', title: 'Permissions products for S3' },
]

export function MarketplacePage() {
  const { hash } = useLocation()

  useEffect(() => {
    if (!hash) return
    document.getElementById(hash.slice(1))?.scrollIntoView()
  }, [hash])

  return (
    <>
      <h1 className="aws-h1">Search all AWS Marketplace products for S3</h1>
      <label className="aws-marketplace-search">
        <span aria-hidden="true">⌕</span>
        <input
          type="search"
          placeholder="Search all AWS Marketplace products for S3"
          aria-label="Search all AWS Marketplace products for S3"
          disabled
          title="To implement"
        />
      </label>
      {ROWS.map((row) => (
        <section key={row.id} className="aws-marketplace-row" id={row.id}>
          <div className="aws-marketplace-row-head">
            <h2>{row.title}</h2>
          </div>
          <div className="aws-empty-panel">
            <strong>Not available on local stack</strong>
            <p>AWS Marketplace is not applicable on the local stack.</p>
          </div>
        </section>
      ))}
    </>
  )
}
