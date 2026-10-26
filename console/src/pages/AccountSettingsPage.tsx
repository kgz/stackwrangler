import { DeadButton, InfoButton } from '../components/S3Ui'

const BPA_SETTINGS = [
  'Block all public access',
  'Block public access to buckets and objects granted through new access control lists (ACLs)',
  'Block public access to buckets and objects granted through any access control lists (ACLs)',
  'Block public access to buckets and objects granted through new public bucket or access point policies',
  'Block public and cross-account access to buckets and objects through any public bucket or access point policies',
]

export function AccountSettingsPage() {
  return (
    <>
      <h1 className="aws-h1">Account and organization settings</h1>
      <section className="aws-card">
        <div className="aws-card-body">
          <div className="aws-toolbar">
            <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
              Block Public Access settings for this account
            </h2>
            <DeadButton>Edit</DeadButton>
          </div>
          <p className="aws-desc">
            Amazon S3 Block Public Access provides settings for access points,
            buckets, and accounts to help you manage public access to Amazon S3
            resources.{' '}
            <a
              href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html"
              target="_blank"
              rel="noopener noreferrer"
            >
              Learn more ↗
            </a>
          </p>
          <dl className="aws-kv">
            {BPA_SETTINGS.map((label) => (
              <div key={label}>
                <dt>{label}</dt>
                <dd>
                  <span className="aws-placeholder">[Setting not loaded]</span>
                </dd>
              </div>
            ))}
          </dl>
        </div>
      </section>
      <section className="aws-card" style={{ marginTop: 16 }}>
        <div className="aws-card-body">
          <div className="aws-toolbar">
            <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
              AWS Organizations settings for Storage Lens <InfoButton />
            </h2>
            <DeadButton>Edit trusted access</DeadButton>
          </div>
          <p className="aws-desc">
            Authorize Storage Lens to access AWS Organizations for
            organization-wide dashboards.{' '}
            <a
              href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-lens-trusted-access.html"
              target="_blank"
              rel="noopener noreferrer"
            >
              Learn more ↗
            </a>
          </p>
          <dl className="aws-kv">
            <div>
              <dt>Trusted access</dt>
              <dd>
                <span className="aws-placeholder">[Status not loaded]</span>
              </dd>
            </div>
          </dl>
        </div>
      </section>
    </>
  )
}
