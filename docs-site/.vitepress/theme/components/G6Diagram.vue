<script setup lang="ts">
import { Graph } from '@antv/g6'
import { onBeforeUnmount, onMounted, ref, watch } from 'vue'
import { getDiagram } from '../diagrams'

const props = defineProps<{
  /** Registry id, e.g. hosting-footprint */
  name: string
}>()

const el = ref<HTMLDivElement | null>(null)
const err = ref<string | null>(null)
let graph: Graph | null = null

async function mountGraph() {
  err.value = null
  graph?.destroy()
  graph = null

  const def = getDiagram(props.name)
  if (!def) {
    err.value = `Unknown diagram: ${props.name}`
    return
  }
  if (!el.value) return

  const width = Math.max(el.value.clientWidth || 720, 720)
  graph = new Graph({
    container: el.value,
    width,
    height: def.height,
    data: def.data,
    animation: false,
    node: {
      type: 'rect',
    },
    edge: {
      type: 'cubic-horizontal',
      style: {
        label: false,
      },
    },
    behaviors: ['drag-canvas', 'zoom-canvas', 'drag-element'],
    plugins: [
      ...(def.background
        ? [
            {
              type: 'background',
              key: 'bg',
              backgroundColor: def.background,
            },
          ]
        : []),
      ...(def.plugins ?? []),
    ],
  })
  await graph.render()
  await graph.fitView({ padding: 28 })
}

onMounted(() => {
  void mountGraph()
  window.addEventListener('resize', onResize)
})

onBeforeUnmount(() => {
  window.removeEventListener('resize', onResize)
  graph?.destroy()
  graph = null
})

function onResize() {
  if (!graph || !el.value) return
  const def = getDiagram(props.name)
  graph.setSize(Math.max(el.value.clientWidth || 720, 720), def?.height ?? 400)
  void graph.fitView({ padding: 28 })
}

watch(
  () => props.name,
  () => {
    void mountGraph()
  },
)
</script>

<template>
  <div class="sw-g6" :class="{ 'sw-g6--dark': !!name }">
    <p v-if="err" class="sw-g6__err">{{ err }}</p>
    <div v-else ref="el" class="sw-g6__canvas" role="img" :aria-label="name" />
    <p class="sw-g6__hint">Drag · scroll to zoom · dashed = sidecar</p>
  </div>
</template>

<style scoped>
.sw-g6 {
  margin: 1.25rem 0 1.75rem;
  border: 1px solid var(--vp-c-divider);
  border-radius: 8px;
  background: var(--vp-c-bg-soft);
  overflow: hidden;
}

.sw-g6--dark {
  background: #1f1d1c;
  border-color: #3a3634;
}

.sw-g6__canvas {
  width: 100%;
  min-height: 320px;
}

.sw-g6__hint {
  margin: 0;
  padding: 0.4rem 0.85rem 0.55rem;
  font-size: 0.75rem;
  color: #a39e99;
  border-top: 1px solid #3a3634;
}

.sw-g6__err {
  margin: 0;
  padding: 1rem;
  color: var(--vp-c-danger-1);
}
</style>
