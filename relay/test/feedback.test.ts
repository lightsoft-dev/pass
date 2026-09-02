import {
  SELF,
  applyD1Migrations,
  env,
  type D1Migration,
} from "cloudflare:test";
import { beforeAll, beforeEach, describe, expect, it, vi } from "vitest";

import {
  handleFeedbackRequest,
  parseSubmission,
} from "../src/feedback";

type TestEnv = Env & { TEST_MIGRATIONS: D1Migration[] };

type FeedbackRow = {
  id: string;
  type: string;
  title: string;
  message: string;
  email: string | null;
  app_version: string | null;
  os_version: string | null;
  forward_status: string;
  created_at: number;
  updated_at: number;
  forwarded_at: number | null;
};

beforeAll(async () => {
  await applyD1Migrations(env.CONTROL_DB, (env as TestEnv).TEST_MIGRATIONS);
});

beforeEach(async () => {
  await env.CONTROL_DB.prepare("DELETE FROM feedback_reports").run();
});

async function feedbackRows(): Promise<FeedbackRow[]> {
  const result = await env.CONTROL_DB.prepare(
    `SELECT id, type, title, message, email, app_version, os_version,
            forward_status, created_at, updated_at, forwarded_at
       FROM feedback_reports
      ORDER BY created_at, id`,
  ).all<FeedbackRow>();
  return result.results;
}

describe("feedback", () => {
  it("accepts feedback into D1 when Notion is not configured", async () => {
    let fetchCalls = 0;
    const result = await handleFeedbackRequest(
      new Request("https://relay.test/v2/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          type: "feedback",
          title: "Should not be forwarded",
          message: "Should not be forwarded",
        }),
      }),
      { CONTROL_DB: env.CONTROL_DB },
      async () => {
        fetchCalls += 1;
        return new Response(null, { status: 204 });
      },
    );

    expect(result?.status).toBe(201);
    const body = await result?.json() as Record<string, unknown>;
    expect(body).toMatchObject({
      ok: true,
      delivery: "queued",
    });
    expect(body.reportId).toMatch(/^feedback_[0-9a-f-]{36}$/);
    expect(fetchCalls).toBe(0);

    const rows = await feedbackRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: body.reportId,
      type: "feedback",
      title: "Should not be forwarded",
      message: "Should not be forwarded",
      email: null,
      app_version: null,
      os_version: null,
      forward_status: "queued",
      forwarded_at: null,
    });
    expect(rows[0]!.created_at).toBe(rows[0]!.updated_at);
  });

  it("validates and trims a submission", () => {
    expect(parseSubmission({
      type: "request",
      title: "  Faster session switching ",
      message: "  Please add numeric shortcuts. ",
      email: "person@example.com",
    })).toEqual({
      type: "request",
      title: "Faster session switching",
      message: "Please add numeric shortcuts.",
      email: "person@example.com",
    });
  });

  it("rejects invalid input", () => {
    expect(() => parseSubmission({
      type: "idea",
      title: "Hello",
      message: "World",
    })).toThrow("valid feedback type");
    expect(() => parseSubmission({
      type: "bug",
      title: "Hello",
      message: "World",
      email: "not-an-email",
    })).toThrow("valid email");
  });

  it("creates a page using the data source's actual title property", async () => {
    const requests: Request[] = [];
    const fetcher = async (input: RequestInfo | URL, init?: RequestInit) => {
      const request = new Request(input, init);
      requests.push(request);
      if (request.method === "GET") {
        return Response.json({
          properties: {
            Status: { type: "status" },
            Summary: { type: "title" },
          },
        });
      }
      return Response.json({ object: "page", id: "page_123" });
    };

    const result = await handleFeedbackRequest(
      new Request("https://relay.test/v2/feedback", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          type: "bug",
          title: "Panel flickers",
          message: "It flickers when switching sessions.",
          appVersion: "0.1.1 (2)",
        }),
      }),
      {
        CONTROL_DB: env.CONTROL_DB,
        NOTION_API_TOKEN: "secret_test",
        NOTION_FEEDBACK_DATA_SOURCE_ID: "source_123",
      },
      fetcher,
    );

    expect(result?.status).toBe(201);
    const responseBody = await result?.json() as Record<string, unknown>;
    expect(responseBody).toMatchObject({ ok: true, delivery: "delivered" });
    expect(responseBody.reportId).toMatch(/^feedback_[0-9a-f-]{36}$/);
    expect(requests).toHaveLength(2);
    const schemaRequest = requests[0]!;
    const createRequest = requests[1]!;
    expect(schemaRequest.url).toBe(
      "https://api.notion.com/v1/data_sources/source_123",
    );
    const body = await createRequest.json() as Record<string, unknown>;
    expect(body.parent).toEqual({
      type: "data_source_id",
      data_source_id: "source_123",
    });
    expect(body.properties).toMatchObject({
      Summary: {
        type: "title",
        title: [{ type: "text", text: { content: "[Bug] Panel flickers" } }],
      },
    });
    expect(createRequest.headers.get("Notion-Version")).toBe("2026-03-11");
    expect(JSON.stringify(body)).toContain(`Report ID: ${String(responseBody.reportId)}`);

    const rows = await feedbackRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: responseBody.reportId,
      type: "bug",
      title: "Panel flickers",
      message: "It flickers when switching sessions.",
      app_version: "0.1.1 (2)",
      forward_status: "delivered",
    });
    expect(rows[0]!.forwarded_at).toBeTypeOf("number");
    expect(rows[0]!.updated_at).toBeGreaterThanOrEqual(rows[0]!.created_at);
  });

  it("keeps the D1 report queued when Notion delivery fails", async () => {
    const log = vi.spyOn(console, "error").mockImplementation(() => undefined);
    const result = await handleFeedbackRequest(
      new Request("https://relay.test/v2/feedback", {
        method: "POST",
        body: JSON.stringify({
          type: "feedback",
          title: "Nice",
          message: "Works well.",
        }),
      }),
      {
        CONTROL_DB: env.CONTROL_DB,
        NOTION_API_TOKEN: "secret_test",
        NOTION_FEEDBACK_DATA_SOURCE_ID: "source_123",
      },
      async () => new Response("secret upstream detail", { status: 500 }),
    );

    expect(result?.status).toBe(202);
    const body = await result?.json() as Record<string, unknown>;
    expect(body).toMatchObject({
      ok: true,
      delivery: "queued",
    });
    expect(JSON.stringify(body)).not.toContain("secret upstream detail");

    const rows = await feedbackRows();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({
      id: body.reportId,
      forward_status: "queued",
      forwarded_at: null,
    });
    expect(log).toHaveBeenCalledOnce();
    expect(log.mock.calls.join(" ")).not.toContain("secret upstream detail");
    expect(log.mock.calls.join(" ")).not.toContain("secret_test");
    log.mockRestore();
  });

  it("keeps body-size limits ahead of persistence and forwarding", async () => {
    let fetchCalls = 0;
    const result = await handleFeedbackRequest(
      new Request("https://relay.test/v2/feedback", {
        method: "POST",
        headers: { "Content-Length": "16385" },
        body: "{}",
      }),
      { CONTROL_DB: env.CONTROL_DB },
      async () => {
        fetchCalls += 1;
        return new Response(null, { status: 204 });
      },
    );

    expect(result?.status).toBe(413);
    expect(await feedbackRows()).toEqual([]);
    expect(fetchCalls).toBe(0);
  });

  it("keeps the feedback route behind its dedicated rate limit", async () => {
    const headers = {
      "CF-Connecting-IP": "198.51.100.31",
      "Content-Type": "application/json",
    };
    for (let attempt = 0; attempt < 10; attempt += 1) {
      const result = await SELF.fetch("https://relay.test/v2/feedback", {
        method: "POST",
        headers,
        body: "not-json",
      });
      expect(result.status).toBe(400);
    }

    const limited = await SELF.fetch("https://relay.test/v2/feedback", {
      method: "POST",
      headers,
      body: "not-json",
    });
    expect(limited.status).toBe(429);
    expect(limited.headers.get("Retry-After")).toBe("60");
  });
});
