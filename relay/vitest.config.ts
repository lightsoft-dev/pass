import { cloudflareTest } from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        // Test-only binding. Production and local development still require a
        // secret supplied outside source control.
        bindings: { RELAY_AUTH_TOKEN: "test-only-pass-relay-token" },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
