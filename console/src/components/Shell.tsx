import { useEffect, useMemo, useRef, useState } from 'react'
import { Link, Outlet, useLocation } from 'react-router-dom'
import { config } from '../lib/config'
import { LabelsProvider } from '../lib/labelsContext'
import {
  SEARCH_INDEX,
  SERVICES,
  crumbFor,
  currentApp,
  formatAccountId,
  type AppId,
  type SearchItem,
} from '../lib/services'
import {
  BellIcon,
  ChevLeftIcon,
  CloseIcon,
  CopyIcon,
  GearIcon,
  GridIcon,
  HelpIcon,
  InfoIcon,
  LogoMark,
  MenuIcon,
  SearchIcon,
  TerminalIcon,
} from './ChromeIcons'

type MenuId =
  | 'services'
  | 'cloudshell'
  | 'notify'
  | 'help'
  | 'settings'
  | 'region'
  | 'account'
  | 'search'

type NavItem = {
  label: string
  to: string
  active: (pathname: string) => boolean
}

type NavSection = {
  id: string
  label: string
  items: NavItem[]
}

type SidebarDef = {
  title: string
  sections: NavSection[]
}

const TO_IMPLEMENT = 'To implement'
const SEARCH_TYPES: SearchItem['type'][] = ['Service', 'Feature']

function exactly(path: string) {
  return (pathname: string) => pathname === path
}

function under(path: string) {
  return (pathname: string) =>
    pathname === path || pathname.startsWith(`${path}/`)
}

const SIDEBARS: Record<AppId, SidebarDef> = {
  s3: {
    title: 'S3',
    sections: [
      {
        id: 'buckets',
        label: 'Buckets',
        items: [
          {
            label: 'General purpose buckets',
            to: '/',
            active: (p) => p === '/' || p.startsWith('/buckets/'),
          },
          {
            label: 'Directory buckets',
            to: '/directory-buckets',
            active: exactly('/directory-buckets'),
          },
          {
            label: 'Table buckets',
            to: '/table-buckets',
            active: exactly('/table-buckets'),
          },
          {
            label: 'Vector buckets',
            to: '/vector-buckets',
            active: exactly('/vector-buckets'),
          },
        ],
      },
      {
        id: 'files',
        label: 'Files',
        items: [
          {
            label: 'File systems',
            to: '/file-systems',
            active: exactly('/file-systems'),
          },
        ],
      },
      {
        id: 'access',
        label: 'Access management and security',
        items: [
          {
            label: 'Access Points',
            to: '/access-points',
            active: exactly('/access-points'),
          },
          {
            label: 'Access Points for FSx',
            to: '/access-points-fsx',
            active: exactly('/access-points-fsx'),
          },
          {
            label: 'Access Grants',
            to: '/access-grants',
            active: exactly('/access-grants'),
          },
          {
            label: 'IAM Access Analyzer',
            to: '/access-analyzer',
            active: exactly('/access-analyzer'),
          },
        ],
      },
      {
        id: 'insights',
        label: 'Storage management and insights',
        items: [
          {
            label: 'Storage Lens',
            to: '/storage-lens',
            active: exactly('/storage-lens'),
          },
          {
            label: 'Batch Operations',
            to: '/batch-operations',
            active: exactly('/batch-operations'),
          },
        ],
      },
    ],
  },
  iam: {
    title: 'IAM',
    sections: [
      {
        id: 'access-mgmt',
        label: 'Access management',
        items: [{ label: 'Users', to: '/iam', active: under('/iam') }],
      },
    ],
  },
  lambda: {
    title: 'Lambda',
    sections: [
      {
        id: 'lambda-main',
        label: 'Lambda',
        items: [{ label: 'Functions', to: '/lambda', active: under('/lambda') }],
      },
    ],
  },
  logs: {
    title: 'CloudWatch',
    sections: [
      {
        id: 'logs-main',
        label: 'Logs',
        items: [{ label: 'Log groups', to: '/logs', active: under('/logs') }],
      },
    ],
  },
  sfn: {
    title: 'Step Functions',
    sections: [
      {
        id: 'sfn-main',
        label: 'Step Functions',
        items: [
          {
            label: 'State machines',
            to: '/stepfunctions',
            active: under('/stepfunctions'),
          },
        ],
      },
    ],
  },
  secretsmanager: {
    title: 'Secrets Manager',
    sections: [
      {
        id: 'secrets-main',
        label: 'Secrets',
        items: [
          {
            label: 'Secrets',
            to: '/secretsmanager',
            active: under('/secretsmanager'),
          },
        ],
      },
    ],
  },
  kinesis: {
    title: 'Kinesis',
    sections: [
      {
        id: 'kinesis-main',
        label: 'Data streams',
        items: [
          {
            label: 'Data streams',
            to: '/kinesis',
            active: under('/kinesis'),
          },
        ],
      },
    ],
  },
  apigw: {
    title: 'API Gateway',
    sections: [
      {
        id: 'apigw-apis',
        label: 'APIs',
        items: [
          { label: 'HTTP APIs', to: '/apigateway', active: under('/apigateway') },
        ],
      },
    ],
  },
  cfn: {
    title: 'CloudFormation',
    sections: [
      {
        id: 'cfn-stacks',
        label: 'Stacks',
        items: [
          { label: 'Stacks', to: '/cloudformation', active: under('/cloudformation') },
        ],
      },
    ],
  },
  transfer: {
    title: 'AWS Transfer Family',
    sections: [
      {
        id: 'xfer-servers',
        label: 'Servers',
        items: [{ label: 'Servers', to: '/transfer', active: under('/transfer') }],
      },
    ],
  },
  rds: {
    title: 'RDS',
    sections: [
      {
        id: 'rds-dbs',
        label: 'Databases',
        items: [{ label: 'Databases', to: '/rds', active: under('/rds') }],
      },
    ],
  },
  ecs: {
    title: 'Elastic Container Service',
    sections: [
      {
        id: 'ecs-clusters-sec',
        label: 'Clusters',
        items: [{ label: 'Clusters', to: '/ecs', active: under('/ecs') }],
      },
    ],
  },
  ec2: {
    title: 'EC2',
    sections: [
      {
        id: 'ec2-instances-sec',
        label: 'Instances',
        items: [{ label: 'Instances', to: '/ec2', active: exactly('/ec2') }],
      },
      {
        id: 'ec2-network',
        label: 'Network & security',
        items: [
          { label: 'VPCs', to: '/ec2/vpcs', active: under('/ec2/vpcs') },
        ],
      },
      {
        id: 'ec2-lb',
        label: 'Load balancing',
        items: [
          {
            label: 'Load balancers',
            to: '/ec2/load-balancers',
            active: under('/ec2/load-balancers'),
          },
        ],
      },
    ],
  },
}

const MARKETPLACE_NAV = [
  { id: 'storage-backup', label: 'Storage, Back-up and Recovery' },
  { id: 'data-integration', label: 'Data Integration and Analytics' },
  { id: 'observability', label: 'Observability and Monitoring' },
  { id: 'security', label: 'Security and Threat Detection' },
  { id: 'permissions', label: 'Permissions' },
]

const SERVICE_CATEGORIES = [
  'Analytics',
  'Application Integration',
  'Blockchain',
  'Business Applications',
  'Cloud Financial Management',
  'Compute',
  'Containers',
  'Customer Enablement',
  'Database',
  'Developer Tools',
  'End User Computing',
  'Front-end Web & Mobile',
  'Game Development',
  'Internet of Things',
  'Machine Learning',
  'Management & Governance',
  'Media Services',
  'Migration & Transfer',
  'Networking & Content Delivery',
  'Quantum Technologies',
  'Robotics',
  'Satellite',
  'Security, Identity & Compliance',
  'Serverless',
  'Storage',
  'VR & AR',
]

const REGIONS = [
  { id: 'ap-southeast-2', label: 'Asia Pacific (Sydney)' },
  { id: 'us-east-1', label: 'US East (N. Virginia)' },
  { id: 'eu-west-1', label: 'Europe (Ireland)' },
  { id: 'ap-northeast-1', label: 'Asia Pacific (Tokyo)' },
]

function navLinkClass(active: boolean, extra?: string) {
  return ['aws-nav-link', extra, active ? 'active' : undefined]
    .filter(Boolean)
    .join(' ')
}

function DeadMenuButton({ children }: { children: string }) {
  return (
    <button type="button" disabled aria-disabled="true" title={TO_IMPLEMENT}>
      {children}
    </button>
  )
}

function Sidebar({
  app,
  pathname,
  hash,
  onCollapse,
}: {
  app: AppId
  pathname: string
  hash: string
  onCollapse: () => void
}) {
  const def = SIDEBARS[app]
  const marketplaceOpen = pathname === '/marketplace'
  return (
    <aside className="aws-sidebar" aria-label={def.title}>
      <div className="aws-sidebar-head">
        <span>{def.title}</span>
        <button
          type="button"
          id="btn-collapse-sidebar"
          aria-label="Collapse navigation"
          onClick={onCollapse}
        >
          <ChevLeftIcon />
        </button>
      </div>
      {def.sections.map((sec) => (
        <details key={sec.id} className="aws-nav-section" open>
          <summary>
            <span className="caret">▾</span>
            {sec.label}
          </summary>
          {sec.items.map((item) => (
            <Link
              key={item.to}
              to={item.to}
              className={navLinkClass(item.active(pathname))}
              aria-current={item.active(pathname) ? 'page' : undefined}
            >
              {item.label}
            </Link>
          ))}
        </details>
      ))}
      {app === 's3' ? (
        <div className="aws-nav-foot">
          <Link
            to="/account-settings"
            className={navLinkClass(pathname === '/account-settings')}
            aria-current={pathname === '/account-settings' ? 'page' : undefined}
          >
            Account and organization settings
          </Link>
          <details
            key={marketplaceOpen ? 'mp-open' : 'mp-closed'}
            className="aws-nav-section aws-nav-marketplace"
            open={marketplaceOpen}
          >
            <summary>
              <span className="caret">▾</span>
              <Link
                to="/marketplace"
                className={`aws-nav-summary-link${marketplaceOpen && !hash ? ' active' : ''}`}
              >
                AWS Marketplace for S3
              </Link>
            </summary>
            {MARKETPLACE_NAV.map((c) => (
              <Link
                key={c.id}
                to={`/marketplace#${c.id}`}
                className={navLinkClass(
                  marketplaceOpen && hash === `#${c.id}`,
                  'aws-nav-sub',
                )}
              >
                {c.label}
              </Link>
            ))}
          </details>
        </div>
      ) : null}
    </aside>
  )
}

function ServicesPanel({ onClose }: { onClose: () => void }) {
  return (
    <nav
      className="aws-services-panel open"
      id="services-panel"
      data-pop="services"
      aria-label="Services"
    >
      <div className="svc-rail">
        <div className="svc-rail-item active" aria-current="true">
          Recently visited
        </div>
        <button
          type="button"
          className="svc-rail-item"
          disabled
          aria-disabled="true"
          title={TO_IMPLEMENT}
        >
          Favorites
        </button>
        <button
          type="button"
          className="svc-rail-item"
          disabled
          aria-disabled="true"
          title={TO_IMPLEMENT}
        >
          All applications
        </button>
        <button
          type="button"
          className="svc-rail-item"
          disabled
          aria-disabled="true"
          title={TO_IMPLEMENT}
        >
          All services
        </button>
        <div className="svc-rail-cats">
          {SERVICE_CATEGORIES.map((name) => (
            <button
              key={name}
              type="button"
              className="svc-cat"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
            >
              {name}
            </button>
          ))}
        </div>
      </div>
      <div className="svc-main">
        <div className="svc-main-head">
          <h2>Recently visited</h2>
          <button
            type="button"
            className="aws-icon-btn"
            aria-label="Close services"
            onClick={onClose}
          >
            <CloseIcon />
          </button>
        </div>
        {SERVICES.map((svc) => (
          <Link key={svc.id} to={svc.to} className="svc-tile" onClick={onClose}>
            <span className="aws-fav-icon">{svc.abbr}</span>
            <span>
              <strong>{svc.name}</strong>
              <span className="svc-tile-desc">{svc.desc}</span>
            </span>
          </Link>
        ))}
      </div>
    </nav>
  )
}

export function Shell() {
  const location = useLocation()
  const app = currentApp(location.pathname)
  const [menu, setMenu] = useState<MenuId | null>(null)
  const [query, setQuery] = useState('')
  const [collapsed, setCollapsed] = useState(false)
  const [mobileOpen, setMobileOpen] = useState(false)
  const searchRef = useRef<HTMLInputElement>(null)

  const hits = useMemo(() => {
    const q = query.trim().toLowerCase()
    if (!q) return []
    return SEARCH_INDEX.filter((item) =>
      item.label.toLowerCase().includes(q),
    ).slice(0, 12)
  }, [query])

  useEffect(() => {
    setMenu(null)
    setMobileOpen(false)
  }, [location.pathname])

  useEffect(() => {
    function onClick(e: MouseEvent) {
      if (!(e.target instanceof Element) || !e.target.closest('[data-pop]')) {
        setMenu(null)
      }
    }
    function onKey(e: KeyboardEvent) {
      if (e.key === 'Escape') setMenu(null)
      if (e.altKey && (e.key === 's' || e.key === 'S')) {
        e.preventDefault()
        searchRef.current?.focus()
        searchRef.current?.select()
      }
    }
    document.addEventListener('click', onClick)
    document.addEventListener('keydown', onKey)
    return () => {
      document.removeEventListener('click', onClick)
      document.removeEventListener('keydown', onKey)
    }
  }, [])

  function toggle(id: MenuId) {
    setMenu((cur) => (cur === id ? null : id))
  }

  function onBurger() {
    if (window.matchMedia('(max-width: 920px)').matches) {
      setMobileOpen((v) => !v)
    } else {
      setCollapsed((v) => !v)
    }
  }

  const accountId = formatAccountId(config.accountId)
  const shellClass = [
    'aws-shell',
    collapsed ? 'sidebar-collapsed' : undefined,
    mobileOpen ? 'sidebar-open-mobile' : undefined,
  ]
    .filter(Boolean)
    .join(' ')
  const group = (type: string) => hits.filter((h) => h.type === type)

  return (
    <LabelsProvider>
      <header className="aws-topnav" role="banner">
        <Link className="aws-logo" to="/" title="stackwrangler">
          <LogoMark />
          <span className="aws-logo-word">stackwrangler</span>
        </Link>
        <button
          type="button"
          className="aws-services-btn"
          data-pop="services"
          aria-expanded={menu === 'services'}
          aria-controls="services-panel"
          onClick={() => toggle('services')}
        >
          <GridIcon />
          <span>Services</span>
        </button>
        <div className="aws-search" data-pop="search">
          <div className="aws-search-field">
            <SearchIcon />
            <input
              ref={searchRef}
              type="search"
              placeholder="Search"
              autoComplete="off"
              aria-label="Search"
              value={query}
              onChange={(e) => {
                setQuery(e.target.value)
                setMenu('search')
              }}
              onFocus={() => {
                if (query.trim()) setMenu('search')
              }}
            />
            <span className="aws-search-kbd">Alt+S</span>
            <button
              type="button"
              className="aws-icon-btn"
              disabled
              aria-disabled="true"
              title={TO_IMPLEMENT}
              aria-label="Search settings"
            >
              <GearIcon />
            </button>
          </div>
          <div
            className={`aws-search-results${menu === 'search' && query.trim() ? ' open' : ''}`}
            role="listbox"
            aria-label="Search results"
          >
            {hits.length === 0 ? (
              <div className="sr-group">
                No matches for “{query.replace(/[<>]/g, '')}”
              </div>
            ) : (
              SEARCH_TYPES.map((type) =>
                group(type).length === 0 ? null : (
                  <div key={type}>
                    <div className="sr-group">{type}</div>
                    {group(type).map((h) => (
                      <Link
                        key={`${type}-${h.to}-${h.label}`}
                        to={h.to}
                        role="option"
                        aria-selected="false"
                        onClick={() => {
                          setQuery('')
                          setMenu(null)
                        }}
                      >
                        <span>{h.label}</span>
                        <span className="sr-meta">{h.type}</span>
                      </Link>
                    ))}
                  </div>
                ),
              )
            )}
          </div>
        </div>
        <div className="aws-top-actions">
          <div className="aws-pop" data-pop="cloudshell">
            <button
              type="button"
              className="aws-icon-btn"
              aria-expanded={menu === 'cloudshell'}
              aria-controls="menu-cloudshell"
              title="CloudShell"
              aria-label="CloudShell"
              onClick={() => toggle('cloudshell')}
            >
              <TerminalIcon />
            </button>
            <div
              className={`aws-menu${menu === 'cloudshell' ? ' open' : ''}`}
              id="menu-cloudshell"
            >
              <div className="label">CloudShell</div>
              <DeadMenuButton>Open CloudShell</DeadMenuButton>
              <DeadMenuButton>CloudShell preferences</DeadMenuButton>
            </div>
          </div>
          <div className="aws-pop" data-pop="notify">
            <button
              type="button"
              className="aws-icon-btn"
              aria-expanded={menu === 'notify'}
              aria-controls="menu-notify"
              title="Notifications"
              aria-label="Notifications"
              onClick={() => toggle('notify')}
            >
              <BellIcon />
            </button>
            <div
              className={`aws-menu${menu === 'notify' ? ' open' : ''}`}
              id="menu-notify"
            >
              <div className="label">Notifications</div>
              <div
                className="label"
                style={{
                  fontWeight: 400,
                  textTransform: 'none',
                  letterSpacing: 0,
                }}
              >
                No new notifications
              </div>
              <div className="sep" />
              <DeadMenuButton>View all notifications</DeadMenuButton>
            </div>
          </div>
          <div className="aws-pop" data-pop="help">
            <button
              type="button"
              className="aws-icon-btn"
              aria-expanded={menu === 'help'}
              aria-controls="menu-help"
              title="Help"
              aria-label="Help"
              onClick={() => toggle('help')}
            >
              <HelpIcon />
            </button>
            <div
              className={`aws-menu wide${menu === 'help' ? ' open' : ''}`}
              id="menu-help"
            >
              <div className="label">Help</div>
              <div className="aws-about-blurb" role="note">
                stackwrangler is not affiliated with Amazon Web Services. Local
                console for AWS-shaped stacks — not an AWS product.
              </div>
              <div className="sep" />
              <DeadMenuButton>Info</DeadMenuButton>
              <a
                href="https://docs.aws.amazon.com/"
                target="_blank"
                rel="noopener noreferrer"
              >
                Documentation
              </a>
              <DeadMenuButton>Support</DeadMenuButton>
            </div>
          </div>
          <div className="aws-pop" data-pop="settings">
            <button
              type="button"
              className="aws-icon-btn"
              aria-expanded={menu === 'settings'}
              aria-controls="menu-settings"
              title="Settings"
              aria-label="Settings"
              onClick={() => toggle('settings')}
            >
              <GearIcon />
            </button>
            <div
              className={`aws-menu${menu === 'settings' ? ' open' : ''}`}
              id="menu-settings"
            >
              <div className="label">Settings</div>
              <DeadMenuButton>Unified Settings</DeadMenuButton>
              <DeadMenuButton>Visual mode</DeadMenuButton>
            </div>
          </div>
          <div className="aws-pop" data-pop="region">
            <button
              type="button"
              className="aws-region-btn"
              aria-expanded={menu === 'region'}
              aria-controls="menu-region"
              onClick={() => toggle('region')}
            >
              <span className="line1">{config.regionLabel} ▾</span>
            </button>
            <div
              className={`aws-menu wide${menu === 'region' ? ' open' : ''}`}
              id="menu-region"
            >
              <div className="label">Regions</div>
              <button
                type="button"
                disabled
                aria-disabled="true"
                aria-current="true"
                title="Current region"
              >
                {config.regionLabel} {config.region}
              </button>
              {REGIONS.filter((r) => r.id !== config.region).map((r) => (
                <button
                  key={r.id}
                  type="button"
                  disabled
                  aria-disabled="true"
                  title={TO_IMPLEMENT}
                >
                  {r.label} {r.id}
                </button>
              ))}
            </div>
          </div>
          <div className="aws-pop" data-pop="account">
            <button
              type="button"
              className="aws-account-btn"
              aria-expanded={menu === 'account'}
              aria-controls="menu-account"
              onClick={() => toggle('account')}
            >
              <span className="line1">Account ID: {accountId} ▾</span>
              <span className="line2">local</span>
            </button>
            <div
              className={`aws-menu aws-account-panel${menu === 'account' ? ' open' : ''}`}
              id="menu-account"
            >
              <div className="acct-row">
                <span className="acct-k">Account ID</span>
                <span className="acct-v">
                  {accountId}
                  <button
                    type="button"
                    className="btn-icon acct-copy"
                    aria-label="Copy account ID"
                    onClick={() => {
                      void navigator.clipboard.writeText(config.accountId)
                    }}
                  >
                    <CopyIcon />
                  </button>
                </span>
              </div>
              <div className="acct-row">
                <span className="acct-k">Account name</span>
                <span className="acct-v">local</span>
              </div>
              <div className="acct-row">
                <span className="acct-k">Account color</span>
                <span className="acct-v">
                  <span className="acct-swatch" aria-hidden="true" /> Default
                </span>
              </div>
              <div className="acct-row">
                <span className="acct-k">Federated user</span>
                <span className="acct-v">local</span>
              </div>
              <div className="sep" />
              <DeadMenuButton>Account</DeadMenuButton>
              <DeadMenuButton>Organization</DeadMenuButton>
              <DeadMenuButton>Service Quotas</DeadMenuButton>
              <DeadMenuButton>Billing and Cost Management</DeadMenuButton>
              <div className="sep" />
              <div className="acct-actions">
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled
                  aria-disabled="true"
                  title={TO_IMPLEMENT}
                >
                  Turn on multi-session support
                </button>
                <button
                  type="button"
                  className="btn btn-normal"
                  disabled
                  aria-disabled="true"
                  title={TO_IMPLEMENT}
                >
                  Switch role
                </button>
                <button
                  type="button"
                  className="btn btn-primary"
                  disabled
                  aria-disabled="true"
                  title={TO_IMPLEMENT}
                >
                  Sign out
                </button>
              </div>
            </div>
          </div>
        </div>
      </header>
      {menu === 'services' ? (
        <ServicesPanel onClose={() => setMenu(null)} />
      ) : null}
      <nav className="aws-favorites" aria-label="Favorites">
        {SERVICES.map((svc) => (
          <Link
            key={svc.id}
            to={svc.to}
            className={`aws-fav${svc.id === app ? ' active' : ''}`}
            aria-current={svc.id === app ? 'page' : undefined}
          >
            <span className="aws-fav-icon">{svc.abbr}</span>
            {svc.name}
          </Link>
        ))}
      </nav>
      <div className="aws-service-bar">
        <button
          type="button"
          className="burger"
          aria-label="Toggle navigation"
          onClick={onBurger}
        >
          <MenuIcon />
        </button>
        <div className="aws-crumbs">
          <Link to={SERVICES.find((s) => s.id === app)?.to ?? '/'}>
            {SIDEBARS[app].title}
          </Link>
          <span className="sep">›</span>
          <span className="current">{crumbFor(location.pathname)}</span>
        </div>
        <button
          type="button"
          className="aws-page-info"
          aria-label="Page info"
          title={TO_IMPLEMENT}
          disabled
          aria-disabled="true"
        >
          <InfoIcon />
        </button>
      </div>
      <div className={shellClass}>
        <Sidebar
          app={app}
          pathname={location.pathname}
          hash={location.hash}
          onCollapse={() => setCollapsed(true)}
        />
        <main className="aws-main" id="content">
          <Outlet />
          <p className="aws-affiliation">
            Not affiliated with Amazon Web Services. Independent local tooling
            for AWS-shaped stacks — see repository LICENSE and THIRD_PARTY.md.
          </p>
        </main>
      </div>
    </LabelsProvider>
  )
}
