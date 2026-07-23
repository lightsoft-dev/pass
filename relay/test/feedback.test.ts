import { describe, expect, it } from "vitest";

import {
  handleFeedbackRequest,
  parseSubmission,
} from "../src/feedback";

describe("feedback", () => {
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
        NOTION_API_TOKEN: "secret_test",
        NOTION_FEEDBACK_DATA_SOURCE_ID: "source_123",
      },
      fetcher,
    );

    expect(result?.status).toBe(201);
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
  });

  it("does not expose Notion errors to the client", async () => {
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
        NOTION_API_TOKEN: "secret_test",
        NOTION_FEEDBACK_DATA_SOURCE_ID: "source_123",
      },
      async () => new Response("secret upstream detail", { status: 500 }),
    );

    expect(result?.status).toBe(502);
    await expect(result?.json()).resolves.toEqual({
      error: {
        code: "feedback_delivery_failed",
        message: "Could not send feedback. Please try again.",
      },
    });
  });
});
