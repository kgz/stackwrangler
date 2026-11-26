import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import { useRoute } from 'vitepress'
import { nextTick, onMounted, watch } from 'vue'
import mediumZoom, { type Zoom } from 'medium-zoom'
import G6Diagram from './components/G6Diagram.vue'
import '../../../design/stackwrangler/tokens.css'
import './custom.css'

let zoom: Zoom | undefined

function bindZoom(): void {
  zoom?.detach()
  zoom = mediumZoom('.vp-doc img:not(.no-zoom), .sw-shot-strip img', {
    background: 'rgba(15, 15, 18, 0.92)',
  })
}

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('G6Diagram', G6Diagram)
  },
  setup() {
    const route = useRoute()
    onMounted(() => {
      void nextTick(bindZoom)
    })
    watch(
      () => route.path,
      () => {
        void nextTick(bindZoom)
      },
    )
  },
} satisfies Theme
