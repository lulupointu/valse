// Release build: esbuild for main/preload/utility, Vite for the renderer.
import { build as esbuild } from 'esbuild';
import { build as vite } from 'vite';
import react from '@vitejs/plugin-react';
import fs from 'node:fs';
import path from 'node:path';

const root = path.dirname(new URL(import.meta.url).pathname);
const dist = path.join(root, 'dist');
fs.rmSync(dist, { recursive: true, force: true });
const t0 = Date.now();
await esbuild({
  entryPoints: {
    main: 'src/main/main.ts',
    preload: 'src/main/preload.ts',
    segUtility: 'src/main/segUtility.ts',
  },
  bundle: true, platform: 'node', format: 'cjs', target: 'node22', outdir: dist,
  external: ['electron', 'onnxruntime-node'], minify: true, sourcemap: false, logLevel: 'warning',
});
await vite({
  root: path.join(root, 'src/renderer'), base: './', logLevel: 'warn',
  plugins: [react()],
  build: { outDir: path.join(dist, 'renderer'), emptyOutDir: true, target: 'esnext', minify: true, chunkSizeWarningLimit: 4000 },
  worker: { format: 'es' },
});
console.error(`[build] done in ${Date.now() - t0} ms`);
