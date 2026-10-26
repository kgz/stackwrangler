import { DeadButton, InfoButton } from '../components/S3Ui'

export function AccessAnalyzerPage() {
  return (
    <>
      <div className="aws-toolbar" style={{ alignItems: 'flex-start' }}>
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1">
            IAM Access Analyzer for S3 <InfoButton />
          </h1>
          <p className="aws-desc">
            When a bucket policy, Access Point policy, or ACL is added or
            modified, IAM Access Analyzer generates and updates findings based
            on the change within 30 minutes. Findings related to account-level
            Block public access settings or Multi-Region Access Point
            configurations may not be generated or updated for up to 6 hours
            after you change the settings. Findings in the following lists are
            aggregated by bucket.{' '}
            <a
              href="https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-analyzer.html"
              target="_blank"
              rel="noopener noreferrer"
            >
              Learn more ↗
            </a>
          </p>
        </div>
        <DeadButton>Download report</DeadButton>
      </div>
      <section className="aws-card">
        <div className="aws-card-body">
          <h2 className="aws-section-title">Findings</h2>
          <div className="aws-empty-panel" data-testid="access-analyzer-empty">
            <strong>No findings to display</strong>
            <p>
              When Access Analyzer finds buckets that allow public or
              cross-account access, they appear here.
            </p>
          </div>
        </div>
      </section>
    </>
  )
}
