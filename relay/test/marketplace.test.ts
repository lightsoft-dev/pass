import {
  SELF,
  applyD1Migrations,
  env,
  type D1Migration,
} from "cloudflare:test";
import { beforeAll, describe, expect, it } from "vitest";

import { hashSecret } from "../src/auth";

type WireObject = Record<string, unknown>;
type TestEnv = Env & { TEST_MIGRATIONS: D1Migration[] };

const PEPPER = "test-only-device-credential-pepper";
const tokens: Record<string, string> = {};

function asObject(value: unknown): WireObject {
  expect(value).toBeTypeOf("object");
  expect(value).not.toBeNull();
  expect(Array.isArray(value)).toBe(false);
  return value as WireObject;
}

function nested(value: WireObject, key: string): WireObject {
  return asObject(value[key]);
}

async function seedCredential(
  label: "owner" | "other" | "admin" | "mobile",
  accountId: string,
  role: "desktop" | "mobile" = "desktop",
): Promise<void> {
  const hex = ({ owner: "1", other: "2", admin: "3", mobile: "4" } as const)[label];
  const credentialId = `cred_${hex.repeat(32)}`;
  const desktopId = `desk_${label}`;
  const subjectId = role === "desktop" ? desktopId : `device_${label}`;
  const secret = label.at(0)!.repeat(43);
  const now = Date.now();
  const statements = [
    env.CONTROL_DB.prepare(
      `INSERT INTO accounts
        (id, oidc_issuer, oidc_subject, display_name, created_at, updated_at)
       VALUES (?, 'https://identity.pass.test/', ?, ?, ?, ?)`,
    ).bind(accountId, `${label}-subject`, `${label} display`, now, now),
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
  const token = options.as ? tokens[options.as] : undefined;
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (options.body) headers.set("Content-Type", "application/json");
  return SELF.fetch(`https://relay.test${path}`, {
    method: options.method ?? (options.body ? "POST" : "GET"),
    headers,
    ...(options.body ? { body: JSON.stringify(options.body) } : {}),
  });
}

function extensionInput(slug: string, overrides: WireObject = {}): WireObject {
  const name = `Extension ${slug}`;
  const version = "1.2.3";
  return {
    repositoryUrl: `https://github.com/pass-test/${slug}.git`,
    name,
    summary: `Summary for ${slug}`,
    description: `Description for ${slug}`,
    category: "productivity",
    tags: ["workflow", "developer-tools"],
    version,
    manifest: {
      apiVersion: 1,
      id: slug,
      name,
      version,
      permissions: ["run:script"],
      contributes: {},
    },
    ...overrides,
  };
}

async function create(slug: string, as: keyof typeof tokens = "owner"): Promise<WireObject> {
  const response = await api("/v2/marketplace/extensions", {
    as,
    body: extensionInput(slug),
  });
  expect(response.status).toBe(201);
  return nested(asObject(await response.json()), "extension");
}

beforeAll(async () => {
  await applyD1Migrations(env.CONTROL_DB, (env as TestEnv).TEST_MIGRATIONS);
  await seedCredential("owner", "acct_owner");
  await seedCredential("other", "acct_other");
  await seedCredential("admin", "acct_admin");
  await seedCredential("mobile", "acct_mobile", "mobile");
});

describe("extension marketplace", () => {
  it("requires an active desktop credential", async () => {
    const missing = await api("/v2/marketplace/extensions");
    expect(missing.status).toBe(401);

    const mobile = await api("/v2/marketplace/extensions", { as: "mobile" });
    expect(mobile.status).toBe(403);
    await expect(mobile.json()).resolves.toMatchObject({
      error: { code: "forbidden" },
    });
  });

  it("publishes validated metadata and supports detail, search, pagination, and conflicts", async () => {
    const first = await create("catalog-alpha");
    expect(first).toMatchObject({
      repositoryUrl: "https://github.com/pass-test/catalog-alpha.git",
      name: "Extension catalog-alpha",
      summary: "Summary for catalog-alpha",
      category: "productivity",
      tags: ["workflow", "developer-tools"],
      version: "1.2.3",
      owner: { id: "acct_owner", displayName: "owner display" },
      installCount: 0,
      isOwner: true,
      canModerate: false,
    });
    expect(first.id).toMatch(/^mkt_[a-f0-9]{32}$/);
    expect(first).not.toHaveProperty("reportCount");
    expect(asObject(first.manifest)).toMatchObject({ id: "catalog-alpha", apiVersion: 1 });

    const detail = await api(`/v2/marketplace/extensions/${String(first.id)}`, { as: "other" });
    expect(detail.status).toBe(200);
    expect(nested(asObject(await detail.json()), "extension").isOwner).toBe(false);

    const second = await create("catalog-beta");
    const pageOne = await api(
      "/v2/marketplace/extensions?q=Summary&category=productivity&limit=1",
      { as: "other" },
    );
    const firstPageBody = asObject(await pageOne.json());
    expect(firstPageBody.extensions).toHaveLength(1);
    expect(firstPageBody.nextCursor).toBeTypeOf("string");
    const pageTwo = await api(
      `/v2/marketplace/extensions?q=Summary&category=productivity&limit=1&cursor=${String(firstPageBody.nextCursor)}`,
      { as: "other" },
    );
    const secondPageBody = asObject(await pageTwo.json());
    expect(secondPageBody.extensions).toHaveLength(1);
    expect(
      [
        String(asObject((firstPageBody.extensions as unknown[])[0]).id),
        String(asObject((secondPageBody.extensions as unknown[])[0]).id),
      ].sort(),
    ).toEqual([String(first.id), String(second.id)].sort());

    const tagSearch = await api(
      "/v2/marketplace/extensions?q=developer-tools&limit=10",
      { as: "other" },
    );
    expect(asObject(await tagSearch.json()).extensions).toHaveLength(2);

    const duplicateRepository = await api("/v2/marketplace/extensions", {
      as: "other",
      body: extensionInput("different-manifest", { repositoryUrl: first.repositoryUrl }),
    });
    expect(duplicateRepository.status).toBe(409);
    await expect(duplicateRepository.json()).resolves.toMatchObject({
      error: { code: "repository_exists" },
    });

    const badManifest = await api("/v2/marketplace/extensions", {
      as: "owner",
      body: extensionInput("bad-manifest", {
        manifest: {
          apiVersion: 1,
          id: "bad-manifest",
          name: "Does not match",
          version: "1.2.3",
        },
      }),
    });
    expect(badManifest.status).toBe(400);
    await expect(badManifest.json()).resolves.toMatchObject({
      error: { code: "manifest_mismatch" },
    });
  });

  it("rejects manifests Swift cannot decode before they can poison catalog responses", async () => {
    const base = extensionInput("shape-guard");
    const manifest = asObject(base.manifest);
    const malformedManifests: WireObject[] = [
      { ...manifest, description: 123 },
      { ...manifest, contributes: "bad" },
      {
        ...manifest,
        contributes: {
          commands: [{ id: "run", title: "Run", run: "not-an-action" }],
        },
      },
      {
        ...manifest,
        contributes: {
          rules: [{
            on: "attention.pending",
            if: { kind: ["decision", 7] },
            run: { notify: { title: "Alert" } },
          }],
        },
      },
      {
        ...manifest,
        contributes: {
          actions: { ping: { notify: { body: "Missing required title" } } },
        },
      },
      {
        ...manifest,
        contributes: {
          windows: [{ id: "main", title: "Main", entry: "index.html", width: "wide" }],
        },
      },
    ];

    for (const malformed of malformedManifests) {
      const response = await api("/v2/marketplace/extensions", {
        as: "owner",
        body: { ...base, manifest: malformed },
      });
      expect(response.status).toBe(400);
      await expect(response.json()).resolves.toMatchObject({
        error: { code: "invalid_manifest" },
      });
    }

    const empty = await api("/v2/marketplace/extensions?q=shape-guard", { as: "other" });
    expect(asObject(await empty.json()).extensions).toHaveLength(0);

    const fullManifest: WireObject = {
      apiVersion: 2,
      id: "shape-guard",
      name: "Extension shape-guard",
      version: "1.2.3",
      description: "Every Codable field has a structurally valid value.",
      permissions: [
        "run:script",
        "notify",
        "session:send",
        "open:url",
        "ui:window",
        "events:attention",
      ],
      contributes: {
        commands: [{
          id: "run",
          title: "Run",
          context: "global",
          run: {
            script: "run.sh",
            args: ["--once"],
            timeoutSeconds: 10,
            terminal: false,
          },
        }],
        rules: [{
          on: "attention.pending",
          if: { kind: ["decision", "input"] },
          run: { notify: { title: "Attention", body: "A session is waiting." } },
        }],
        actions: {
          send: { sendText: "Continue" },
          source: { openURL: "https://github.com/pass-test/shape-guard" },
          window: { openWindow: "main" },
        },
        windows: [{
          id: "main",
          title: "Main",
          entry: "index.html",
          width: 960,
          height: 640.5,
          subscriptions: ["attention.pending"],
        }],
      },
    };
    const published = await api("/v2/marketplace/extensions", {
      as: "owner",
      body: { ...base, manifest: fullManifest },
    });
    expect(published.status).toBe(201);

    const catalog = await api("/v2/marketplace/extensions?q=shape-guard", { as: "other" });
    const catalogItems = asObject(await catalog.json()).extensions as unknown[];
    expect(catalogItems).toHaveLength(1);
    expect(asObject(catalogItems[0]).manifest).toEqual(fullManifest);
  });

  it("rejects lone UTF-16 surrogates recursively without poisoning the catalog", async () => {
    const base = extensionInput("unicode-guard");
    const manifest = asObject(base.manifest);
    const invalidBodies = [
      {
        ...base,
        manifest: {
          ...manifest,
          contributes: {
            actions: {
              nested: { notify: { title: `Invalid ${"\ud800"}` } },
            },
          },
        },
      },
      {
        ...base,
        manifest: {
          ...manifest,
          contributes: {
            actions: {
              [`invalid-${"\udc00"}`]: { sendText: "Continue" },
            },
          },
        },
      },
    ];

    for (const body of invalidBodies) {
      const rejected = await api("/v2/marketplace/extensions", {
        as: "owner",
        body,
      });
      expect(rejected.status).toBe(400);
      await expect(rejected.json()).resolves.toMatchObject({
        error: { code: "invalid_json" },
      });
    }

    const catalogBefore = await api(
      "/v2/marketplace/extensions?q=unicode-guard",
      { as: "other" },
    );
    expect(catalogBefore.status).toBe(200);
    expect(asObject(await catalogBefore.json()).extensions).toHaveLength(0);

    const valid = await api("/v2/marketplace/extensions", {
      as: "owner",
      body: {
        ...base,
        summary: "Valid supplementary Unicode: 🚀",
      },
    });
    expect(valid.status).toBe(201);

    const catalogAfter = await api(
      "/v2/marketplace/extensions?q=unicode-guard",
      { as: "other" },
    );
    expect(catalogAfter.status).toBe(200);
    const items = asObject(await catalogAfter.json()).extensions as unknown[];
    expect(items).toHaveLength(1);
    expect(asObject(items[0]).summary).toBe("Valid supplementary Unicode: 🚀");
  });

  it("enforces ownership for updates and deletes", async () => {
    const extension = await create("ownership-test");
    const installed = await api(`/v2/marketplace/extensions/${String(extension.id)}/install`, {
      as: "other",
      method: "POST",
    });
    expect(await installed.json()).toEqual({ counted: true, installCount: 1 });
    const deniedUpdate = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "other",
      method: "PATCH",
      body: { summary: "Not yours" },
    });
    expect(deniedUpdate.status).toBe(403);

    const updated = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "owner",
      method: "PATCH",
      body: {
        summary: "Updated summary",
        description: null,
        category: "automation",
        tags: ["automation", "automation"],
      },
    });
    expect(updated.status).toBe(200);
    expect(nested(asObject(await updated.json()), "extension")).toMatchObject({
      summary: "Updated summary",
      category: "automation",
      tags: ["automation"],
    });

    const identicalIdentity = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "owner",
      method: "PATCH",
      body: {
        repositoryUrl: extension.repositoryUrl,
        manifest: asObject(extension.manifest),
      },
    });
    expect(identicalIdentity.status).toBe(200);

    const repointed = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "owner",
      method: "PATCH",
      body: { repositoryUrl: "https://github.com/pass-test/repointed.git" },
    });
    expect(repointed.status).toBe(409);
    await expect(repointed.json()).resolves.toMatchObject({
      error: { code: "repository_immutable" },
    });

    const changedManifest = {
      ...asObject(extension.manifest),
      id: "ownership-test-replacement",
    };
    const changedManifestID = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "owner",
      method: "PATCH",
      body: { manifest: changedManifest },
    });
    expect(changedManifestID.status).toBe(409);
    await expect(changedManifestID.json()).resolves.toMatchObject({
      error: { code: "manifest_id_immutable" },
    });

    const preserved = await api(`/v2/marketplace/extensions/${String(extension.id)}`, { as: "owner" });
    expect(nested(asObject(await preserved.json()), "extension")).toMatchObject({
      repositoryUrl: extension.repositoryUrl,
      manifest: { id: "ownership-test" },
      installCount: 1,
    });

    const deniedDelete = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "other",
      method: "DELETE",
    });
    expect(deniedDelete.status).toBe(403);

    const deleted = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "owner",
      method: "DELETE",
    });
    expect(deleted.status).toBe(200);
    const missing = await api(`/v2/marketplace/extensions/${String(extension.id)}`, { as: "owner" });
    expect(missing.status).toBe(404);
  });

  it("counts unique installs and accepts one updatable report per account", async () => {
    const extension = await create("install-report-test");
    const firstInstall = await api(`/v2/marketplace/extensions/${String(extension.id)}/install`, {
      as: "other",
      method: "POST",
    });
    expect(await firstInstall.json()).toEqual({ counted: true, installCount: 1 });
    const retry = await api(`/v2/marketplace/extensions/${String(extension.id)}/install`, {
      as: "other",
      method: "POST",
    });
    expect(await retry.json()).toEqual({ counted: false, installCount: 1 });
    const installAudits = await env.CONTROL_DB.prepare(
      `SELECT COUNT(*) AS count FROM audit_events
        WHERE account_id = ? AND target_id = ?
          AND action = 'marketplace.extension.install'`,
    ).bind("acct_other", extension.id).first<{ count: number }>();
    expect(installAudits?.count).toBe(1);

    const selfReport = await api(`/v2/marketplace/extensions/${String(extension.id)}/reports`, {
      as: "owner",
      body: { reason: "spam" },
    });
    expect(selfReport.status).toBe(409);

    const report = await api(`/v2/marketplace/extensions/${String(extension.id)}/reports`, {
      as: "other",
      body: { reason: "malware", details: "Unexpected executable" },
    });
    expect(report.status).toBe(201);
    expect(nested(asObject(await report.json()), "report")).toMatchObject({
      extensionId: extension.id,
      reason: "malware",
    });
    const replacement = await api(`/v2/marketplace/extensions/${String(extension.id)}/reports`, {
      as: "other",
      body: { reason: "misleading" },
    });
    expect(replacement.status).toBe(200);
    expect(nested(asObject(await replacement.json()), "report").reason).toBe("misleading");

    const ordinaryDetail = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "other",
    });
    expect(nested(asObject(await ordinaryDetail.json()), "extension")).not.toHaveProperty(
      "reportCount",
    );
    const adminDetail = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "admin",
    });
    expect(nested(asObject(await adminDetail.json()), "extension").reportCount).toBe(1);
    const adminList = await api(
      "/v2/marketplace/extensions?q=install-report-test",
      { as: "admin" },
    );
    const adminItems = asObject(await adminList.json()).extensions as unknown[];
    expect(adminItems).toHaveLength(1);
    expect(asObject(adminItems[0]).reportCount).toBe(1);
  });

  it("allows configured administrators to hide listings without exposing them to browsers", async () => {
    const extension = await create("moderation-test");
    const nonAdmin = await api(`/v2/marketplace/extensions/${String(extension.id)}/moderation`, {
      as: "other",
      method: "PATCH",
      body: { hidden: true },
    });
    expect(nonAdmin.status).toBe(403);

    const hidden = await api(`/v2/marketplace/extensions/${String(extension.id)}/moderation`, {
      as: "admin",
      method: "PATCH",
      body: { hidden: true },
    });
    expect(hidden.status).toBe(200);
    const hiddenExtension = nested(asObject(await hidden.json()), "extension");
    expect(hiddenExtension).toMatchObject({
      isHidden: true,
      canModerate: true,
    });
    const repeatedHide = await api(`/v2/marketplace/extensions/${String(extension.id)}/moderation`, {
      as: "admin",
      method: "PATCH",
      body: { hidden: true },
    });
    expect(repeatedHide.status).toBe(200);
    const repeatedHiddenExtension = nested(asObject(await repeatedHide.json()), "extension");
    expect(repeatedHiddenExtension).toMatchObject({
      isHidden: true,
      updatedAt: hiddenExtension.updatedAt,
    });
    const hideAudits = await env.CONTROL_DB.prepare(
      `SELECT COUNT(*) AS count FROM audit_events
        WHERE account_id = ? AND target_id = ?
          AND action = 'marketplace.extension.hide'`,
    ).bind("acct_admin", extension.id).first<{ count: number }>();
    expect(hideAudits?.count).toBe(1);

    const invisible = await api(`/v2/marketplace/extensions/${String(extension.id)}`, { as: "other" });
    expect(invisible.status).toBe(404);
    const ordinaryList = await api(
      "/v2/marketplace/extensions?q=moderation-test",
      { as: "other" },
    );
    expect(asObject(await ordinaryList.json()).extensions).toHaveLength(0);
    const adminList = await api(
      "/v2/marketplace/extensions?q=moderation-test",
      { as: "admin" },
    );
    const adminExtensions = asObject(await adminList.json()).extensions as unknown[];
    expect(adminExtensions).toHaveLength(1);
    expect(asObject(adminExtensions[0])).toMatchObject({
      id: extension.id,
      isHidden: true,
      canModerate: true,
    });
    const ownerList = await api("/v2/marketplace/extensions?owner=me&q=moderation", { as: "owner" });
    const ownerExtensions = asObject(await ownerList.json()).extensions as unknown[];
    expect(ownerExtensions).toHaveLength(1);
    expect(asObject(ownerExtensions[0]).isHidden).toBe(true);

    const unhidden = await api(`/v2/marketplace/extensions/${String(extension.id)}/moderation`, {
      as: "admin",
      method: "PATCH",
      body: { hidden: false },
    });
    expect(unhidden.status).toBe(200);
    const visibleAgain = await api(`/v2/marketplace/extensions/${String(extension.id)}`, { as: "other" });
    expect(visibleAgain.status).toBe(200);
  });

  it("lets administrators remove a disputed hidden listing and release its identities", async () => {
    const extension = await create("admin-recovery-test");
    const ordinaryDelete = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "other",
      method: "DELETE",
    });
    expect(ordinaryDelete.status).toBe(403);

    const hidden = await api(`/v2/marketplace/extensions/${String(extension.id)}/moderation`, {
      as: "admin",
      method: "PATCH",
      body: { hidden: true },
    });
    expect(hidden.status).toBe(200);
    const deleted = await api(`/v2/marketplace/extensions/${String(extension.id)}`, {
      as: "admin",
      method: "DELETE",
    });
    expect(deleted.status).toBe(200);
    await expect(deleted.json()).resolves.toEqual({
      deleted: true,
      extensionId: extension.id,
    });
    const audit = await env.CONTROL_DB.prepare(
      `SELECT account_id, actor_id, action FROM audit_events
        WHERE target_id = ? AND action = 'marketplace.extension.delete'
        ORDER BY id DESC LIMIT 1`,
    ).bind(extension.id).first<{
      account_id: string;
      actor_id: string;
      action: string;
    }>();
    expect(audit).toEqual({
      account_id: "acct_admin",
      actor_id: "desk_admin",
      action: "marketplace.extension.delete",
    });
    const deleteAuditCount = await env.CONTROL_DB.prepare(
      `SELECT COUNT(*) AS count FROM audit_events
        WHERE target_id = ? AND action = 'marketplace.extension.delete'`,
    ).bind(extension.id).first<{ count: number }>();
    expect(deleteAuditCount?.count).toBe(1);

    const replacement = await api("/v2/marketplace/extensions", {
      as: "other",
      body: extensionInput("admin-recovery-test"),
    });
    expect(replacement.status).toBe(201);
    expect(nested(asObject(await replacement.json()), "extension").owner).toMatchObject({
      id: "acct_other",
    });
  });
});
