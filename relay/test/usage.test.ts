import {
  SELF,
  applyD1Migrations,
  env,
  type D1Migration,
} from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

import { hashSecret } from "../src/auth";

type TestEnv = Env & { TEST_MIGRATIONS: D1Migration[] };
type WireObject = Record<string, unknown>;

const PEPPER = "test-only-device-credential-pepper";
const tokens: Record<string, string> = {};

async function seedCredential(
  label: "usage-a" | "usage-b" | "usage-mobile",
  accountId: string,
  role: "desktop" | "mobile" = "desktop",
): Promise<void> {
  const hex = ({ "usage-a": "a", "usage-b": "b", "usage-mobile": "c" } as const)[label];
  const credentialId = `cred_${hex.repeat(32)}`;
  const desktopId = `desk_${label}`;
  const subjectId = role === "desktop" ? desktopId : `device_${label}`;
  const secret = hex.repeat(43);
  const now = Date.now();
  const statements = [
    env.CONTROL_DB.prepare(
      `INSERT INTO accounts
        (id, oidc_issuer, oidc_subject, email, display_name, created_at, updated_at)
       VALUES (?, 'https://identity.pass.test/', ?, ?, ?, ?, ?)`,
    ).bind(
      accountId,
      `${label}-subject`,
      `${label}@example.test`,
      label === "usage-a" ? "Ada" : "Ben",
      now,
      now,
    ),
    env.CONTROL_DB.prepare(
      "INSERT INTO desktops (id, account_id, name, created_at) VALUES (?, ?, ?, ?)",
    ).bind(desktopId, accountId, `${label} desktop`, now),
  ];
  if (role === "mobile") {
    statements.push(
      env.CONTROL_DB.prepare(
        `INSERT INTO devices (id, account_id, name, platform, created_at)
         VALUES (?, ?, ?, 'macos', ?)`,
      ).bind(subjectId, accountId, `${label} device`, now),
      env.CONTROL_DB.prepare(
        `INSERT INTO desktop_devices (desktop_id, device_id, scopes_json, paired_at)
         VALUES (?, ?, '[]', ?)`,
      ).bind(desktopId, subjectId, now),
    );
  }
  statements.push(
    env.CONTROL_DB.prepare(
      `INSERT INTO credentials
        (id, account_id, subject_type, subject_id, desktop_id, role, kind,
         secret_hash, scopes_json, issued_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, 'access', ?, '[]', ?, ?)`,
    ).bind(
      credentialId,
      accountId,
      role === "desktop" ? "desktop" : "device",
      subjectId,
      desktopId,
      role,
      await hashSecret(secret, PEPPER),
      now,
      now + 60 * 60 * 1_000,
    ),
  );
  await env.CONTROL_DB.batch(statements);
  tokens[label] = `pass_at_${credentialId}.${secret}`;
}

async function api(
  path: string,
  options: {
    as?: keyof typeof tokens;
    method?: string;
    body?: WireObject;
  } = {},
): Promise<Response> {
  const headers = new Headers();
  if (options.as) headers.set("Authorization", `Bearer ${tokens[options.as]}`);
  if (options.body) headers.set("Content-Type", "application/json");
  return SELF.fetch(`https://relay.test${path}`, {
    method: options.method ?? (options.body ? "PUT" : "GET"),
    headers,
    ...(options.body ? { body: JSON.stringify(options.body) } : {}),
  });
}

function dateKey(offsetDays = 0): string {
  return new Date(Date.now() + offsetDays * 24 * 60 * 60 * 1_000)
    .toISOString()
    .slice(0, 10);
}

function usageRow(
  total: number,
  provider = "claude",
  date = dateKey(),
): WireObject {
  return {
    date,
    provider,
    inputTokens: total,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
  };
}

function asObject(value: unknown): WireObject {
  expect(value).toBeTypeOf("object");
  expect(value).not.toBeNull();
  expect(Array.isArray(value)).toBe(false);
  return value as WireObject;
}

beforeAll(async () => {
  await applyD1Migrations(env.CONTROL_DB, (env as TestEnv).TEST_MIGRATIONS);
  await seedCredential("usage-a", "acct_usage_a");
  await seedCredential("usage-b", "acct_usage_b");
  await seedCredential("usage-mobile", "acct_usage_mobile", "mobile");
});

describe("usage leaderboard", () => {
  it("requires a registered desktop credential", async () => {
    expect((await api("/v2/usage/leaderboard")).status).toBe(401);
    const mobile = await api("/v2/usage/leaderboard", { as: "usage-mobile" });
    expect(mobile.status).toBe(403);
  });

  it("validates aggregate-only uploads", async () => {
    const invalid = await api("/v2/usage/snapshots", {
      as: "usage-a",
      body: {
        days: [
          usageRow(100, "unknown"),
          { ...usageRow(100), project: "secret-project" },
        ],
      },
    });
    expect(invalid.status).toBe(400);
    await expect(invalid.json()).resolves.toMatchObject({
      error: { code: "invalid_usage" },
    });

    const duplicate = await api("/v2/usage/snapshots", {
      as: "usage-a",
      body: { days: [usageRow(10), usageRow(20)] },
    });
    expect(duplicate.status).toBe(400);
  });

  it("ranks opted-in accounts and never exposes account ids or emails", async () => {
    const first = await api("/v2/usage/snapshots", {
      as: "usage-a",
      body: {
        days: [
          usageRow(120, "claude"),
          usageRow(80, "codex"),
          usageRow(999, "pi", dateKey(-10)),
        ],
      },
    });
    expect(first.status).toBe(200);
    await expect(first.json()).resolves.toMatchObject({
      sharing: true,
      publishedRows: 3,
    });
    const second = await api("/v2/usage/snapshots", {
      as: "usage-b",
      body: { days: [usageRow(300, "pi")] },
    });
    expect(second.status).toBe(200);

    const response = await api("/v2/usage/leaderboard?days=7", { as: "usage-a" });
    expect(response.status).toBe(200);
    const body = asObject(await response.json());
    expect(body).toMatchObject({ periodDays: 7, sharing: true });
    const leaderboard = body.leaderboard as WireObject[];
    expect(leaderboard).toHaveLength(2);
    expect(leaderboard.map((row) => [row.rank, row.displayName, row.totalTokens])).toEqual([
      [1, "Ben", 300],
      [2, "Ada", 200],
    ]);
    expect(leaderboard[1]).toMatchObject({ isMe: true });
    expect(leaderboard[0]).not.toHaveProperty("accountId");
    expect(JSON.stringify(body)).not.toContain("@example.test");

    const month = asObject(await (
      await api("/v2/usage/leaderboard?days=30", { as: "usage-a" })
    ).json());
    expect(asObject(month.me).totalTokens).toBe(1_199);
  });

  it("replaces one desktop snapshot instead of accumulating retries", async () => {
    const replacement = await api("/v2/usage/snapshots", {
      as: "usage-a",
      body: { days: [usageRow(25, "claude")] },
    });
    expect(replacement.status).toBe(200);
    const leaderboard = asObject(await (
      await api("/v2/usage/leaderboard?days=7", { as: "usage-a" })
    ).json()).leaderboard as WireObject[];
    const ada = leaderboard.find((row) => row.displayName === "Ada");
    expect(ada?.totalTokens).toBe(25);
  });

  it("supports a complete opt-out", async () => {
    const removed = await api("/v2/usage/snapshots", {
      as: "usage-a",
      method: "DELETE",
    });
    expect(removed.status).toBe(200);
    await expect(removed.json()).resolves.toMatchObject({
      sharing: false,
      removed: true,
    });
    const body = asObject(await (
      await api("/v2/usage/leaderboard?days=7", { as: "usage-a" })
    ).json());
    expect(body.sharing).toBe(false);
    expect(body.me).toBeNull();
    expect((body.leaderboard as WireObject[]).some((row) => row.displayName === "Ada")).toBe(false);
  });
});
