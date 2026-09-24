import { defineConfig } from "vite";

// Part B: dev proxy so `npm run dev:web` (vite) can call the brain (`npm
// start`, port 8787 by default) without a CORS dance. `npm run build`
// bundles into dist/, which Server.res serves statically at runtime.
export default defineConfig({
  server: {
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8787",
        changeOrigin: true,
      },
    },
  },
});
