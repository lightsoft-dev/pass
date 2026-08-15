import assert from "node:assert/strict";
import test from "node:test";

import {
  CONTENT_REPORT_LIMITS,
  ContentReportError,
  buildContentReportSubmission,
  submitContentReport,
} from "./feedbackService.ts";

test("builds a bounded report from only the selected response and report fields", () => {
  assert.deepEqual(
    buildContentReportSubmission({
      sourceMessageID: "message_123",
      reason: "privacy",
      excerpt: "  This is the selected assistant response.  ",
      note: "  It appears to expose a secret.  ",
    }),
    {
      type: "feedback",
      title: "AI response report: Privacy or security concern",
      message: [
        "Reason: Privacy or security concern",
        "Source message ID: message_123",
        "Reported response:\nThis is the selected assistant response.",
        "Additional note:\nIt appears to expose a secret.",
      ].join("\n\n"),
    },
  );
});

test("submits anonymously to the configured relay and preserves the source message ID", async () => {
  let requestedURL = "";
  let requestedInit: RequestInit | undefined;
  const fetchImpl = (async (input: RequestInfo | URL, init?: RequestInit) => {
    requestedURL = String(input);
    requestedInit = init;
    return Response.json(
      { ok: true, reportId: "feedback_123", delivery: "queued" },
      { status: 202 },
    );
  }) as typeof fetch;

  const result = await submitContentReport(
    "https://relay.example.com/console/?ignored=1#fragment",
    {
      sourceMessageID: "msg_original_9",
      reason: "incorrect",
      excerpt: "The selected answer",
    },
    { fetchImpl },
  );

  assert.deepEqual(result, { reportId: "feedback_123", delivery: "queued" });
  assert.equal(requestedURL, "https://relay.example.com/console/v2/feedback");
  assert.equal(requestedInit?.method, "POST");
  assert.equal(requestedInit?.credentials, "omit");
  assert.equal(requestedInit?.redirect, "error");
  const headers = new Headers(requestedInit?.headers);
  assert.equal(headers.get("Authorization"), null);
  assert.equal(headers.get("Cookie"), null);
  assert.equal(headers.get("Content-Type"), "application/json");
  assert.ok(requestedInit?.signal instanceof AbortSignal);
  const payload = JSON.parse(String(requestedInit?.body)) as Record<string, unknown>;
  assert.deepEqual(Object.keys(payload).sort(), ["message", "title", "type"]);
  assert.match(String(payload.message), /Source message ID: msg_original_9/);
  assert.match(String(payload.message), /The selected answer/);
  assert.doesNotMatch(JSON.stringify(payload), /account|credential|project path|terminal/i);
});

test("times out a stalled report so the user can retry", async () => {
  const stalledFetch = ((_input: RequestInfo | URL, init?: RequestInit) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener(
        "abort",
        () => reject(new DOMException("aborted", "AbortError")),
        { once: true },
      );
    })) as typeof fetch;

  await assert.rejects(
    submitContentReport(
      "https://relay.example.com",
      {
        sourceMessageID: "message_123",
        reason: "unsafe",
        excerpt: "selected response",
      },
      { fetchImpl: stalledFetch, timeoutMilliseconds: 5 },
    ),
    /timed out/i,
  );
});

test("rejects oversized or malformed report fields before sending", async () => {
  let fetchCalls = 0;
  const fetchImpl = (async () => {
    fetchCalls += 1;
    return Response.json({ ok: true });
  }) as typeof fetch;

  await assert.rejects(
    submitContentReport(
      "https://relay.example.com",
      {
        sourceMessageID: "message_123",
        reason: "other",
        excerpt: "x".repeat(CONTENT_REPORT_LIMITS.excerpt + 1),
      },
      { fetchImpl },
    ),
    /3500 characters or fewer/,
  );
  await assert.rejects(
    submitContentReport(
      "https://relay.example.com",
      {
        sourceMessageID: "message\ninjected",
        reason: "other",
        excerpt: "selected response",
      },
      { fetchImpl },
    ),
    /source message ID is invalid/i,
  );
  assert.equal(fetchCalls, 0);
});

test("surfaces safe relay and rate-limit errors", async () => {
  const relayError = (async () =>
    Response.json(
      { error: { code: "invalid_feedback", message: "Choose a valid report." } },
      { status: 400 },
    )) as typeof fetch;
  await assert.rejects(
    submitContentReport(
      "https://relay.example.com",
      {
        sourceMessageID: "message_123",
        reason: "other",
        excerpt: "selected response",
      },
      { fetchImpl: relayError },
    ),
    (error: unknown) => {
      assert.ok(error instanceof ContentReportError);
      assert.equal(error.status, 400);
      assert.equal(error.code, "invalid_feedback");
      assert.equal(error.message, "Choose a valid report.");
      return true;
    },
  );

  const rateLimited = (async () =>
    Response.json({ error: { message: "internal detail" } }, { status: 429 })) as typeof fetch;
  await assert.rejects(
    submitContentReport(
      "https://relay.example.com",
      {
        sourceMessageID: "message_123",
        reason: "other",
        excerpt: "selected response",
      },
      { fetchImpl: rateLimited },
    ),
    /wait a minute/i,
  );
});
