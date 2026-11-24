import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

export default defineConfig({
  plugins: [react()],
  server: {
    port: 5173,
    proxy: { "/api": "http://localhost:3001" },
  },
  optimizeDeps: {
    // These load WASM and spawn workers via import.meta.url, which Vite's pre-bundling breaks
    exclude: [
      "@aztec/bb.js",
      "@aztec-foundation/bb.js",
      "@noir-lang/noir_js",
      "@noir-lang/noirc_abi",
      "@noir-lang/acvm_js",
    ],
    esbuildOptions: { target: "esnext" },
  },
  build: { target: "esnext" },
})
