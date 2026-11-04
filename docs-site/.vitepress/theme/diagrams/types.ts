import type { GraphData } from '@antv/g6'

export type SwDiagram = {
  id: string
  title: string
  height: number
  data: GraphData
  /** G6 plugins (hull, legend, …) */
  plugins?: Record<string, unknown>[]
  /** Canvas fill behind the graph */
  background?: string
}
