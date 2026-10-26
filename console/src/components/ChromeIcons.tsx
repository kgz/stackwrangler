import type { ReactNode } from 'react'

function Icon({ children }: { children: ReactNode }) {
  return (
    <svg width="16" height="16" viewBox="0 0 24 24" aria-hidden="true">
      {children}
    </svg>
  )
}

export function GridIcon() {
  return (
    <Icon>
      {[5, 12, 19].flatMap((y) =>
        [5, 12, 19].map((x) => <circle key={`${x}-${y}`} cx={x} cy={y} r="1.5" />),
      )}
    </Icon>
  )
}

export function SearchIcon() {
  return (
    <Icon>
      <circle cx="11" cy="11" r="7" />
      <path d="M20 20l-3.5-3.5" />
    </Icon>
  )
}

export function GearIcon() {
  return (
    <Icon>
      <circle cx="12" cy="12" r="3" />
      <path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" />
    </Icon>
  )
}

export function TerminalIcon() {
  return (
    <Icon>
      <path d="M4 6h16v12H4z" />
      <path d="M7 10l3 2-3 2M12 14h5" />
    </Icon>
  )
}

export function BellIcon() {
  return (
    <Icon>
      <path d="M6 16h12l-1.5-2.5V10a4.5 4.5 0 10-9 0v3.5L6 16z" />
      <path d="M10 18a2 2 0 004 0" />
    </Icon>
  )
}

export function HelpIcon() {
  return (
    <Icon>
      <circle cx="12" cy="12" r="9" />
      <path d="M9.5 9a2.5 2.5 0 115 1c0 1.5-2.5 2-2.5 3.5" />
      <circle cx="12" cy="17" r="0.8" fill="currentColor" stroke="none" />
    </Icon>
  )
}

export function InfoIcon() {
  return (
    <Icon>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 10v6M12 7.5v.5" />
    </Icon>
  )
}

export function MenuIcon() {
  return (
    <Icon>
      <path d="M4 7h16M4 12h16M4 17h16" />
    </Icon>
  )
}

export function ChevLeftIcon() {
  return (
    <Icon>
      <path d="M14 6l-6 6 6 6" />
    </Icon>
  )
}

export function CopyIcon() {
  return (
    <Icon>
      <rect x="8" y="8" width="10" height="10" rx="1" />
      <path d="M6 14V6a1 1 0 011-1h8" />
    </Icon>
  )
}

export function CloseIcon() {
  return (
    <Icon>
      <path d="M6 6l12 12M18 6L6 18" />
    </Icon>
  )
}

export function LogoMark() {
  return (
    <svg
      className="aws-logo-mark"
      viewBox="0 0 18 18"
      aria-hidden="true"
    >
      <rect
        x="1.5"
        y="1.5"
        width="15"
        height="15"
        rx="2"
        fill="none"
        stroke="currentColor"
        strokeWidth="2"
      />
      <path d="M9 4.5v9" fill="none" stroke="currentColor" strokeWidth="2" />
    </svg>
  )
}
