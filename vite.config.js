import { defineConfig } from "vite";

// Part B: dev proxy so `npm run dev:web` (vite) can call the brain (`npm
// start`, port 8787 by default) without a CORS dance. `npm run build`
// bundles into dist/, which Server.res serves statically at runtime.
//
// allowedHosts: true so `tailscale serve` can point at this dev server
// (not just at the brain's own port) for testing the rewind panel over
// the tailnet — Vite's default host check rejects any request whose Host
// header isn't localhost/127.0.0.1, and tailscale serve forwards the
// tailnet hostname (foo.tailXXXX.ts.net) as-is. Safe here: the real
// boundary is Tailscale's own ACLs, not this check, and this dev server
// is never what npm run build/npm start ship.
export default defineConfig({
  server: {
    allowedHosts: true,
    proxy: {
      "/api": {
        target: "http://127.0.0.1:8787",
        changeOrigin: true,
      },
    },
  },
});
