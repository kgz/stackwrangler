import { useContext, type ReactNode } from 'react'
import { LabelsContext } from '../lib/labelsContext'
import { matchAny } from '../lib/labelMatch'

export function ResourceLabel({
  ids,
  detail = false,
  children,
}: {
  ids: Array<string | undefined>
  detail?: boolean
  children?: ReactNode
}) {
  const entries = useContext(LabelsContext)
  const match = matchAny(entries, ids)
  if (!match) return <>{children}</>

  return (
    <span className="resource-id">
      {children}
      <span
        className="resource-label"
        data-resource-label={match.label}
        title={match.note}
      >
        {match.link ? (
          <a
            className="resource-label-link"
            href={match.link}
            onClick={(event) => event.stopPropagation()}
          >
            {match.label}
          </a>
        ) : (
          <span className="resource-label-text">{match.label}</span>
        )}
        {detail && match.note ? (
          <span className="resource-label-note">{match.note}</span>
        ) : null}
      </span>
    </span>
  )
}
