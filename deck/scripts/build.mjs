import { cp, mkdir } from "node:fs/promises";
import { build } from "esbuild";

await mkdir("dist/renderer", { recursive: true });
await Promise.all([
  build({
    entryPoints: ["src/main.ts"],
    outfile: "dist/main.cjs",
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node22",
    external: ["electron"],
  }),
  build({
    entryPoints: ["src/preload.ts"],
    outfile: "dist/preload.cjs",
    bundle: true,
    platform: "node",
    format: "cjs",
    target: "node22",
    external: ["electron"],
  }),
  build({
    entryPoints: ["src/renderer/app.ts"],
    outfile: "dist/renderer/app.js",
    bundle: true,
    platform: "browser",
    format: "iife",
    target: "chrome136",
  }),
  cp("src/renderer/index.html", "dist/renderer/index.html"),
  cp("src/renderer/styles.css", "dist/renderer/styles.css"),
]);
