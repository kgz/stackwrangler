import type { ReactNode } from 'react'
import { FilterHeader, TableTools, TO_IMPLEMENT } from './S3Ui'

type StatusKind = 'success' | 'danger' | 'progress' | 'neutral'

export function statusKind(status: string | undefined): StatusKind {
  const s = (status ?? '').toLowerCase()
  if (!s) return 'neutral'
  if (s.includes('failed') || s.includes('rollback') || s === 'error') {
    return 'danger'
  }
  if (
    s.includes('in_progress') ||
    s.includes('pending') ||
    s.includes('creating') ||
    s.includes('starting') ||
    s.includes('stopping') ||
    s.includes('modifying') ||
    s.includes('deleting') ||
    s.includes('provisioning')
  ) {
    return 'progress'
  }
  if (s.startsWith('delete') || s === 'stopped' || s === 'terminated') {
    return 'neutral'
  }
  if (
    s.includes('complete') ||
    s === 'running' ||
    s === 'available' ||
    s === 'active' ||
    s === 'online' ||
    s === 'associated'
  ) {
    return 'success'
  }
  return 'neutral'
}

export function titleCase(s: string | undefined): string {
  if (!s) return '—'
  return s.charAt(0).toUpperCase() + s.slice(1).toLowerCase()
}

export function StatusBadge({
  status,
  label,
}: {
  status: string | undefined
  label?: string
}) {
  return (
    <span className={`aws-status aws-status-${statusKind(status)}`}>
      {label ?? status ?? '—'}
    </span>
  )
}

export function Mono({ children }: { children: ReactNode }) {
  return <code className="aws-mono">{children}</code>
}

export function Notices({
  error,
  toast,
}: {
  error?: string | null
  toast?: string | null
}) {
  return (
    <>
      {error ? <div className="error-banner">{error}</div> : null}
      {toast ? (
        <div className="toast-banner" role="status">
          {toast}
        </div>
      ) : null}
    </>
  )
}

/** Resource name that has no detail page yet. */
export function DeadLink({ children }: { children: ReactNode }) {
  return (
    <button
      type="button"
      className="aws-dead-link"
      disabled
      aria-disabled="true"
      title={TO_IMPLEMENT}
    >
      {children}
    </button>
  )
}

export function PlainHeader({ children }: { children: string }) {
  return (
    <th scope="col">
      <span className="th-inner">{children}</span>
    </th>
  )
}

export function SortHeader({ children }: { children: string }) {
  return (
    <th scope="col">
      <span className="th-inner">
        {children} <span aria-hidden="true">↑</span>
      </span>
    </th>
  )
}

export { FilterHeader }

export function SelectHeader() {
  return <th className="check" scope="col" aria-label="Select" />
}

export function SelectCell({
  name,
  id,
  selected,
  onToggle,
}: {
  name: string
  id: string
  selected: boolean
  onToggle: (id: string) => void
}) {
  return (
    <td className="check" onClick={(e) => e.stopPropagation()}>
      <input
        type="radio"
        name={name}
        checked={selected}
        aria-label={`Select ${id}`}
        onChange={() => onToggle(id)}
        onClick={() => {
          if (selected) onToggle(id)
        }}
      />
    </td>
  )
}

export function EmptyRow({
  colSpan,
  loading,
  loadingText,
  title,
  text,
}: {
  colSpan: number
  loading: boolean
  loadingText: string
  title: string
  text?: string
}) {
  return (
    <tr>
      <td className="empty-cell" colSpan={colSpan}>
        {loading ? (
          loadingText
        ) : (
          <>
            <strong>{title}</strong>
            {text ?? ''}
          </>
        )}
      </td>
    </tr>
  )
}

/** Title, description, action toolbar, find + pager, and table slot. */
export function ListCard({
  title,
  desc,
  notices,
  toolbar,
  placeholder,
  filter,
  onFilter,
  children,
}: {
  title: ReactNode
  desc?: ReactNode
  notices?: ReactNode
  toolbar: ReactNode
  placeholder: string
  filter: string
  onFilter: (v: string) => void
  children: ReactNode
}) {
  return (
    <>
      <h1 className="aws-h1">{title}</h1>
      {desc ? <p className="aws-desc">{desc}</p> : null}
      {notices}
      <section className="aws-card">
        <div className="aws-card-body">
          <div className="aws-toolbar">{toolbar}</div>
          <TableTools
            placeholder={placeholder}
            value={filter}
            onChange={onFilter}
          />
          <div className="aws-table-wrap">{children}</div>
        </div>
      </section>
    </>
  )
}

export function DetailHeader({
  title,
  subtitle,
  actions,
}: {
  title: ReactNode
  subtitle?: ReactNode
  actions: ReactNode
}) {
  return (
    <>
      <div className="aws-toolbar">
        <div style={{ flex: 1, minWidth: 0 }}>
          <h1 className="aws-h1" style={{ margin: 0 }}>
            {title}
          </h1>
        </div>
        {actions}
      </div>
      {subtitle ? <div className="aws-subtitle-row">{subtitle}</div> : null}
    </>
  )
}

export function Section({
  title,
  children,
  spaced = false,
}: {
  title: string
  children: ReactNode
  spaced?: boolean
}) {
  return (
    <section className="aws-card" style={spaced ? { marginTop: 16 } : undefined}>
      <div className="aws-card-body">
        <h2 className="aws-section-title">{title}</h2>
        {children}
      </div>
    </section>
  )
}

export function Kv({ rows }: { rows: Array<[string, ReactNode]> }) {
  return (
    <dl className="aws-kv">
      {rows.map(([label, value]) => (
        <div key={label}>
          <dt>{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  )
}

export function TabBar<T extends string>({
  tabs,
  active,
  onChange,
}: {
  tabs: ReadonlyArray<readonly [T, string]>
  active: T
  onChange: (id: T) => void
}) {
  return (
    <div className="aws-tabs" role="tablist">
      {tabs.map(([id, label]) => (
        <button
          key={id}
          type="button"
          className={`aws-tab${active === id ? ' active' : ''}`}
          aria-current={active === id ? 'page' : undefined}
          onClick={() => onChange(id)}
        >
          {label}
        </button>
      ))}
    </div>
  )
}
