import { defineConfig } from "vite";

export default defineConfig({
  server: {
    strictPort: true,
    port: 5173,
    host: "127.0.0.1",
  },
  build: {
    target: ["chrome105", "safari13"],
  },
});
