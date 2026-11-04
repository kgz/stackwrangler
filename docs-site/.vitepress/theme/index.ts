import type { Theme } from 'vitepress'
import DefaultTheme from 'vitepress/theme'
import G6Diagram from './components/G6Diagram.vue'
import './custom.css'

export default {
  extends: DefaultTheme,
  enhanceApp({ app }) {
    app.component('G6Diagram', G6Diagram)
  },
} satisfies Theme
