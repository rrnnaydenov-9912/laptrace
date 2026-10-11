import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Relative base so the build works under any path, e.g. https://<user>.github.io/laptrace/
export default defineConfig({
  base: './',
  plugins: [react()],
})
