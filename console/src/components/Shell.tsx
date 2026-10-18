import { useState, type ReactNode } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { config } from '../lib/config'

type SectionId = 'buckets' | 'files' | 'access' | 'storage' | 'marketplace'

function Section({
  id,
  label,
  open,
  onToggle,
  children,
}: {
  id: SectionId
  label: string
  open: boolean
  onToggle: (id: SectionId) => void
  children: ReactNode
}) {
  return (
    <div className="nav-section">
      <button
        type="button"
        className="nav-section-toggle"
        aria-expanded={open}
        onClick={() => onToggle(id)}
      >
        <span className={`chev ${open ? 'open' : ''}`} aria-hidden>
          ▸
        </span>
        {label}
      </button>
      {open ? <div className="nav-section-items">{children}</div> : null}
    </div>
  )
}

function itemClass({ isActive }: { isActive: boolean }): string | undefined {
  return isActive ? 'active' : undefined
}

export function Shell() {
  const [open, setOpen] = useState<Record<SectionId, boolean>>({
    buckets: true,
    files: true,
    access: true,
    storage: true,
    marketplace: false,
  })

  function toggle(id: SectionId) {
    setOpen((prev) => ({ ...prev, [id]: !prev[id] }))
  }

  return (
    <div className="app-shell">
      <header className="top-nav">
        <NavLink to="/" className="brand">
          <span className="brand-mark" aria-hidden />
          awsbox
        </NavLink>
        <div className="search" aria-label="Search">
          <input readOnly placeholder="Search  [Alt+S]" />
        </div>
        <div className="top-meta">
          <span>{config.regionLabel}</span>
          <span>local ({config.accountId})</span>
        </div>
      </header>
      <div className="fav-bar">
        <span>S3</span>
        <span>EC2</span>
        <span>IAM</span>
      </div>
      <div className="body">
        <aside className="sidebar">
          <div className="sidebar-title-row">
            <h2>Amazon S3</h2>
          </div>

          <Section id="buckets" label="Buckets" open={open.buckets} onToggle={toggle}>
            <NavLink to="/" end className={itemClass}>
              General purpose buckets
            </NavLink>
            <NavLink to="/directory-buckets" className={itemClass}>
              Directory buckets
            </NavLink>
            <NavLink to="/table-buckets" className={itemClass}>
              Table buckets
            </NavLink>
            <NavLink to="/vector-buckets" className={itemClass}>
              Vector buckets
            </NavLink>
          </Section>

          <Section id="files" label="Files" open={open.files} onToggle={toggle}>
            <NavLink to="/file-systems" className={itemClass}>
              File systems
            </NavLink>
          </Section>

          <Section
            id="access"
            label="Access management and security"
            open={open.access}
            onToggle={toggle}
          >
            <NavLink to="/access-points" className={itemClass}>
              Access Points
            </NavLink>
            <NavLink to="/access-points-fsx" className={itemClass}>
              Access Points for FSx
            </NavLink>
            <NavLink to="/access-grants" className={itemClass}>
              Access Grants
            </NavLink>
            <NavLink to="/access-analyzer" className={itemClass}>
              IAM Access Analyzer
            </NavLink>
          </Section>

          <Section
            id="storage"
            label="Storage management and insights"
            open={open.storage}
            onToggle={toggle}
          >
            <NavLink to="/storage-lens" className={itemClass}>
              Storage Lens
            </NavLink>
            <NavLink to="/batch-operations" className={itemClass}>
              Batch Operations
            </NavLink>
          </Section>

          <div className="sidebar-footer">
            <NavLink to="/account-settings" className={itemClass}>
              Account and organization settings
            </NavLink>
            <Section
              id="marketplace"
              label="AWS Marketplace for S3"
              open={open.marketplace}
              onToggle={toggle}
            >
              <NavLink to="/marketplace" className={itemClass}>
                Browse offerings
              </NavLink>
            </Section>
          </div>
        </aside>
        <main className="main">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
