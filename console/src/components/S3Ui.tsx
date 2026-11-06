import type { ReactNode } from 'react'
import { Link } from 'react-router-dom'

export const TO_IMPLEMENT = 'To implement'

export function InfoButton() {
  return (
    <button
      type="button"
      className="info"
      disabled
      aria-disabled="true"
      title={TO_IMPLEMENT}
    >
      Info
    </button>
  )
}

export function DeadButton({
  children,
  variant = 'normal',
  label,
  title = TO_IMPLEMENT,
}: {
  children: ReactNode
  variant?: 'normal' | 'primary'
  label?: string
  title?: string
}) {
  return (
    <button
      type="button"
      className={`btn btn-${variant}`}
      disabled
      aria-disabled="true"
      title={title}
      aria-label={label}
    >
      {children}
    </button>
  )
}

export function RefreshButton({
  onClick,
  disabled,
}: {
  onClick?: () => void
  disabled?: boolean
}) {
  if (!onClick) {
    return (
      <button
        type="button"
        className="btn-icon"
        aria-label="Refresh"
        title={TO_IMPLEMENT}
        disabled
        aria-disabled="true"
      >
        ↻
      </button>
    )
  }
  return (
    <button
      type="button"
      className="btn-icon"
      aria-label="Refresh"
      title="Refresh"
      disabled={disabled}
      onClick={onClick}
    >
      ↻
    </button>
  )
}

export function Pager() {
  return (
    <div className="aws-pager">
      <button type="button" disabled aria-label="Previous">
        ‹
      </button>
      <span className="page">1</span>
      <button type="button" disabled aria-label="Next">
        ›
      </button>
      <button
        type="button"
        className="btn-icon"
        aria-label="Table settings"
        title={TO_IMPLEMENT}
        disabled
        aria-disabled="true"
      >
        ⚙
      </button>
    </div>
  )
}

export function TableTools({
  placeholder,
  value,
  onChange,
}: {
  placeholder: string
  value: string
  onChange: (v: string) => void
}) {
  return (
    <div className="aws-table-tools">
      <label className="aws-find">
        <span aria-hidden="true">⌕</span>
        <input
          type="search"
          placeholder={placeholder}
          aria-label={placeholder}
          value={value}
          onChange={(e) => onChange(e.target.value)}
        />
      </label>
      <Pager />
    </div>
  )
}

export function FilterHeader({ children }: { children: string }) {
  return (
    <th scope="col">
      <span className="th-inner">
        {children}{' '}
        <button
          type="button"
          className="filter"
          disabled
          aria-disabled="true"
          title={TO_IMPLEMENT}
          aria-label={`Filter ${children}`}
        >
          ▾
        </button>
      </span>
    </th>
  )
}

export function BucketTypeTabs({ active }: { active: 'gp' | 'directory' }) {
  return (
    <div className="aws-tabs">
      <Link
        className={`aws-tab${active === 'gp' ? ' active' : ''}`}
        to="/"
        aria-current={active === 'gp' ? 'page' : undefined}
      >
        General purpose buckets <span className="aws-badge">All AWS Regions</span>
      </Link>
      <Link
        className={`aws-tab${active === 'directory' ? ' active' : ''}`}
        to="/directory-buckets"
        aria-current={active === 'directory' ? 'page' : undefined}
      >
        Directory buckets
      </Link>
    </div>
  )
}

/** Card with title row, disabled Refresh and Create — for S3 areas the local stack does not provide. */
export function UnavailableListPage({
  title,
  heading,
  createLabel,
  emptyTitle,
  emptyText,
  testId,
}: {
  title: string
  heading: string
  createLabel: string
  emptyTitle: string
  emptyText: string
  testId: string
}) {
  return (
    <>
      <h1 className="aws-h1">{title}</h1>
      <section className="aws-card">
        <div className="aws-card-body">
          <div className="aws-toolbar">
            <h2 className="aws-section-title" style={{ margin: 0, flex: 1 }}>
              {heading}
            </h2>
            <RefreshButton />
            <DeadButton variant="primary">{createLabel}</DeadButton>
          </div>
          <div className="aws-empty-panel" data-testid={testId}>
            <strong>{emptyTitle}</strong>
            <p>{emptyText}</p>
          </div>
        </div>
      </section>
    </>
  )
}
