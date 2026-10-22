import { createContext, useEffect, useState, type ReactNode } from 'react'
import { fetchLabelEntries, type LabelEntry } from './labelMatch'

export const LabelsContext = createContext<LabelEntry[]>([])

export function LabelsProvider({ children }: { children: ReactNode }) {
  const [entries, setEntries] = useState<LabelEntry[]>([])

  useEffect(() => {
    let cancelled = false
    void fetchLabelEntries().then((next) => {
      if (!cancelled) setEntries(next)
    })
    return () => {
      cancelled = true
    }
  }, [])

  return (
    <LabelsContext.Provider value={entries}>{children}</LabelsContext.Provider>
  )
}
