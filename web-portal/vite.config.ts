import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Static build goes to dist-web/ so it doesn't clash with the tsc output (dist/,
// used by the node:test suite). `npm run dev` serves on :5173.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173 },
  build: { outDir: "dist-web" },
});
