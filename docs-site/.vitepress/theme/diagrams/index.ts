import { hostingFootprint } from './hosting-footprint'
import type { SwDiagram } from './types'

const registry: Record<string, SwDiagram> = {
  [hostingFootprint.id]: hostingFootprint,
}

export function getDiagram(id: string): SwDiagram | undefined {
  return registry[id]
}

export type { SwDiagram }
