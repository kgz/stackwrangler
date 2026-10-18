import { NavLink, Outlet } from 'react-router-dom'
import { config } from '../lib/config'

export function Shell() {
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
          <span>
            local ({config.accountId})
          </span>
        </div>
      </header>
      <div className="fav-bar">
        <span>S3</span>
        <span>EC2</span>
        <span>IAM</span>
      </div>
      <div className="body">
        <aside className="sidebar">
          <h2>Amazon S3</h2>
          <div className="nav-section">
            <div className="label">Buckets</div>
            <NavLink
              to="/"
              end
              className={({ isActive }) => (isActive ? 'active' : undefined)}
            >
              General purpose buckets
            </NavLink>
            <span className="nav-item" style={{ display: 'block', padding: '6px 16px 6px 28px', color: 'var(--aws-text-muted)' }}>
              Directory buckets
            </span>
            <span className="nav-item" style={{ display: 'block', padding: '6px 16px 6px 28px', color: 'var(--aws-text-muted)' }}>
              Table buckets
            </span>
          </div>
          <div className="nav-section">
            <div className="label">Access Points</div>
            <span style={{ display: 'block', padding: '6px 16px 6px 28px', color: 'var(--aws-text-muted)' }}>
              Access Points
            </span>
          </div>
        </aside>
        <main className="main">
          <Outlet />
        </main>
      </div>
    </div>
  )
}
