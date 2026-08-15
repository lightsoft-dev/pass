import {
  cloudflareTest,
  readD1Migrations,
} from "@cloudflare/vitest-pool-workers";
import { defineConfig } from "vitest/config";

const TEST_APPLE_PRIVATE_KEY = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgMKrP1bjfDiEAUb3J
toyP8WKRy2UcVLZM/vMydRPTzHuhRANCAATMExhyYIE1ib+H1SIXqf+6cN/lyKKN
VC8n+XjPzjYQnx2Ahy3i6D3E0PA5PQf4NOygfG4vhjXNubiVJYiQhfSy
-----END PRIVATE KEY-----`;

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
          NOTION_API_TOKEN: "test-only-notion-token",
          NOTION_FEEDBACK_DATA_SOURCE_ID: "test-feedback-data-source",
          ALLOW_DEVELOPMENT_AUTH: "true",
          OIDC_ISSUER: "https://identity.pass.test/",
          OIDC_AUDIENCE: "pass-public-api",
          OIDC_JWKS_URL: "https://identity.pass.test/.well-known/jwks.json",
          APPLE_OIDC_ISSUER: "https://appleid.apple.com",
          APPLE_OIDC_AUDIENCE: "dev.lightsoft.passmobile",
          APPLE_OIDC_JWKS_URL: "https://appleid.apple.com/auth/keys",
          APPLE_TEAM_ID: "H66C2M66DC",
          APPLE_CLIENT_ID: "dev.lightsoft.passmobile",
          APPLE_KEY_ID: "TESTKEY123",
          APPLE_PRIVATE_KEY: TEST_APPLE_PRIVATE_KEY,
          APPLE_TOKEN_ENCRYPTION_KEY: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
          GOOGLE_CLIENT_ID: "pass-public-api",
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
