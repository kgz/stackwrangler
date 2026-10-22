import { useState, type ReactNode } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { config } from '../lib/config'
import { LabelsProvider } from '../lib/labelsContext'

type SectionId = 'buckets' | 'files' | 'access' | 'storage' | 'marketplace'
type AppId =
  | 's3'
  | 'iam'
  | 'lambda'
  | 'logs'
  | 'apigw'
  | 'cfn'
  | 'transfer'
  | 'rds'
  | 'ecs'
  | 'ec2'

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
        className="nav-section-title"
        onClick={() => onToggle(id)}
        aria-expanded={open}
      >
        {label}
      </button>
      {open ? <div className="nav-section-body">{children}</div> : null}
    </div>
  )
}

function itemClass({ isActive }: { isActive: boolean }) {
  return isActive ? 'nav-item active' : 'nav-item'
}

function S3Sidebar({
  open,
  toggle,
}: {
  open: Record<SectionId, boolean>
  toggle: (id: SectionId) => void
}) {
  return (
    <>
      <h2 className="sidebar-title">Amazon S3</h2>
      <Section
        id="buckets"
        label="Buckets"
        open={open.buckets}
        onToggle={toggle}
      >
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
      <Section id="access" label="Access" open={open.access} onToggle={toggle}>
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
        label="Storage"
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
      <div className="nav-section">
        <NavLink to="/account-settings" className={itemClass}>
          Account settings
        </NavLink>
      </div>
      <Section
        id="marketplace"
        label="Marketplace"
        open={open.marketplace}
        onToggle={toggle}
      >
        <div className="nav-section-body">
          <NavLink to="/marketplace" className={itemClass}>
            Browse
          </NavLink>
        </div>
      </Section>
    </>
  )
}

function SimpleSidebar({
  title,
  to,
  label,
}: {
  title: string
  to: string
  label: string
}) {
  return (
    <>
      <h2 className="sidebar-title">{title}</h2>
      <div className="nav-section">
        <div className="nav-section-body">
          <NavLink to={to} end className={itemClass}>
            {label}
          </NavLink>
        </div>
      </div>
    </>
  )
}

function Ec2Sidebar() {
  return (
    <>
      <h2 className="sidebar-title">EC2</h2>
      <div className="nav-section">
        <div className="nav-section-body">
          <NavLink to="/ec2" end className={itemClass}>
            Instances
          </NavLink>
          <NavLink to="/ec2/vpcs" className={itemClass}>
            Your VPCs
          </NavLink>
          <NavLink to="/ec2/load-balancers" className={itemClass}>
            Load balancers
          </NavLink>
        </div>
      </div>
    </>
  )
}

function currentApp(pathname: string): AppId {
  if (pathname.startsWith('/iam')) return 'iam'
  if (pathname.startsWith('/lambda')) return 'lambda'
  if (pathname.startsWith('/logs')) return 'logs'
  if (pathname.startsWith('/apigateway')) return 'apigw'
  if (pathname.startsWith('/cloudformation')) return 'cfn'
  if (pathname.startsWith('/transfer')) return 'transfer'
  if (pathname.startsWith('/rds')) return 'rds'
  if (pathname.startsWith('/ecs')) return 'ecs'
  if (pathname.startsWith('/ec2')) return 'ec2'
  return 's3'
}

export function Shell() {
  const location = useLocation()
  const app = currentApp(location.pathname)
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
    <LabelsProvider>
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
        <NavLink to="/" className={() => (app === 's3' ? 'active' : undefined)}>
          S3
        </NavLink>
        <NavLink to="/iam" className={() => (app === 'iam' ? 'active' : undefined)}>
          IAM
        </NavLink>
        <NavLink
          to="/lambda"
          className={() => (app === 'lambda' ? 'active' : undefined)}
        >
          Lambda
        </NavLink>
        <NavLink
          to="/apigateway"
          className={() => (app === 'apigw' ? 'active' : undefined)}
        >
          API Gateway
        </NavLink>
        <NavLink
          to="/logs"
          className={() => (app === 'logs' ? 'active' : undefined)}
        >
          CloudWatch
        </NavLink>
        <NavLink
          to="/cloudformation"
          className={() => (app === 'cfn' ? 'active' : undefined)}
        >
          CloudFormation
        </NavLink>
        <NavLink
          to="/transfer"
          className={() => (app === 'transfer' ? 'active' : undefined)}
        >
          Transfer
        </NavLink>
        <NavLink
          to="/rds"
          className={() => (app === 'rds' ? 'active' : undefined)}
        >
          RDS
        </NavLink>
        <NavLink
          to="/ecs"
          className={() => (app === 'ecs' ? 'active' : undefined)}
        >
          ECS
        </NavLink>
        <NavLink
          to="/ec2"
          className={() => (app === 'ec2' ? 'active' : undefined)}
        >
          EC2
        </NavLink>
      </div>
      <div className="body">
        <aside className="sidebar">
          {app === 'iam' ? (
            <SimpleSidebar title="IAM" to="/iam" label="Users" />
          ) : app === 'lambda' ? (
            <SimpleSidebar title="Lambda" to="/lambda" label="Functions" />
          ) : app === 'logs' ? (
            <SimpleSidebar title="CloudWatch" to="/logs" label="Log groups" />
          ) : app === 'apigw' ? (
            <SimpleSidebar title="API Gateway" to="/apigateway" label="HTTP APIs" />
          ) : app === 'cfn' ? (
            <SimpleSidebar
              title="CloudFormation"
              to="/cloudformation"
              label="Stacks"
            />
          ) : app === 'transfer' ? (
            <SimpleSidebar
              title="AWS Transfer Family"
              to="/transfer"
              label="Servers"
            />
          ) : app === 'rds' ? (
            <SimpleSidebar title="RDS" to="/rds" label="Databases" />
          ) : app === 'ecs' ? (
            <SimpleSidebar title="ECS" to="/ecs" label="Clusters" />
          ) : app === 'ec2' ? (
            <Ec2Sidebar />
          ) : (
            <S3Sidebar open={open} toggle={toggle} />
          )}
        </aside>
        <main className="main">
          <Outlet />
        </main>
      </div>
    </div>
    </LabelsProvider>
  )
}
