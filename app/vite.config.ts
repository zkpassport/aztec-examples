import react from "@vitejs/plugin-react"
import { defineConfig } from "vite"

const proxy = { "/api": "http://localhost:3001" }

export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy },
  // The page's Aztec wallet runs from a build: its stores start a SQLite worker the dev server
  // can't serve
  preview: { port: 5173, proxy },
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
