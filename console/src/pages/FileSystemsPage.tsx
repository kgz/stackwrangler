import { DeadButton, FilterHeader, InfoButton, Pager, RefreshButton } from '../components/S3Ui'

export function FileSystemsPage() {
  return (
    <>
      <h1 className="aws-h1">
        File systems <InfoButton />
      </h1>
      <p className="aws-desc">
        Amazon S3 Files is a high-performance shared file system to access S3
        data from any AWS compute service.
      </p>
      <div className="aws-toolbar">
        <RefreshButton />
        <DeadButton>View details</DeadButton>
        <DeadButton>Delete</DeadButton>
        <div className="spacer" />
        <DeadButton variant="primary">Create file system</DeadButton>
        <Pager />
      </div>
      <details className="aws-getting-started" open>
        <summary>Getting started with S3 Files</summary>
        <p className="aws-desc" style={{ margin: '12px 0 0' }}>
          Create a file system, attach it to a general purpose bucket, and
          mount it from your compute environment.
        </p>
      </details>
      <div className="aws-table-wrap" style={{ marginTop: 16 }}>
        <table className="aws-table" data-testid="file-systems-empty">
          <thead>
            <tr>
              <th className="check" scope="col">
                <input type="checkbox" aria-label="Select all" disabled />
              </th>
              <FilterHeader>File system ID</FilterHeader>
              <FilterHeader>Name</FilterHeader>
              <FilterHeader>General purpose bucket</FilterHeader>
              <FilterHeader>Status</FilterHeader>
              <FilterHeader>Creation date</FilterHeader>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td className="empty-cell" colSpan={6}>
                <strong>No file systems</strong>
                You don&apos;t have any file systems in this Region.
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </>
  )
}
