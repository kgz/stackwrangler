import { useState } from 'react'
import { useLocation } from 'react-router-dom'
import {
  BucketTypeTabs,
  DeadButton,
  FilterHeader,
  InfoButton,
  RefreshButton,
  TableTools,
  UnavailableListPage,
} from '../components/S3Ui'
import { config } from '../lib/config'

export function SpecialtyBucketsPage() {
  const { pathname } = useLocation()
  const [find, setFind] = useState('')

  if (pathname.includes('table')) {
    return (
      <UnavailableListPage
        title="Table buckets"
        heading="Table buckets (0)"
        createLabel="Create table bucket"
        emptyTitle="No table buckets"
        emptyText="S3 Tables are not available on this local stack. Use General purpose buckets."
        testId="table-buckets-empty"
      />
    )
  }

  if (pathname.includes('vector')) {
    return (
      <UnavailableListPage
        title="Vector buckets"
        heading="Vector buckets (0)"
        createLabel="Create vector bucket"
        emptyTitle="No vector buckets"
        emptyText="S3 Vectors are not available on this local stack. Use General purpose buckets."
        testId="vector-buckets-empty"
      />
    )
  }

  return (
    <>
      <h1 className="aws-h1">Buckets</h1>
      <section className="aws-card">
        <BucketTypeTabs active="directory" />
        <div className="aws-card-body">
          <h2 className="aws-section-title">
            Directory buckets (0) <InfoButton />
          </h2>
          <p className="aws-desc">
            Directory buckets are optimized for use cases that require
            consistent single-digit millisecond latency.
          </p>
          <div className="aws-toolbar">
            <RefreshButton />
            <DeadButton>Copy ARN</DeadButton>
            <DeadButton>Empty</DeadButton>
            <DeadButton>Delete</DeadButton>
            <DeadButton>Import</DeadButton>
            <div className="spacer" />
            <DeadButton variant="primary">Create bucket</DeadButton>
          </div>
          <TableTools
            placeholder="Find buckets by name"
            value={find}
            onChange={setFind}
          />
          <div className="aws-table-wrap">
            <table className="aws-table" data-testid="directory-buckets-empty">
              <thead>
                <tr>
                  <th scope="col">
                    <span className="th-inner">
                      Name <span aria-hidden="true">↑</span>
                    </span>
                  </th>
                  <FilterHeader>Bucket location type</FilterHeader>
                  <FilterHeader>Bucket location name</FilterHeader>
                  <FilterHeader>Creation date</FilterHeader>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td className="empty-cell" colSpan={4}>
                    <strong>No buckets</strong>
                    You don&apos;t have any directory buckets in the{' '}
                    {config.regionLabel} {config.region} Region.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </section>
    </>
  )
}
