import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./migrations");

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        // Test-only binding. Production and local development still require a
        // secret supplied outside source control.
        bindings: {
          RELAY_AUTH_TOKEN: "test-only-pass-relay-token",
          DEVICE_CREDENTIAL_PEPPER: "test-only-device-credential-pepper",
          ALLOW_DEVELOPMENT_AUTH: "true",
          OIDC_ISSUER: "https://identity.pass.test/",
          OIDC_AUDIENCE: "pass-public-api",
          OIDC_JWKS_URL: "https://identity.pass.test/.well-known/jwks.json",
          MARKETPLACE_ADMIN_ACCOUNT_IDS: "acct_admin",
          TEST_MIGRATIONS: migrations,
        },
      },
    }),
  ],
  test: {
    include: ["test/**/*.test.ts"],
  },
});
