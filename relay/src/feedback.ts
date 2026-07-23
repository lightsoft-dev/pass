const NOTION_API_BASE = "https://api.notion.com/v1";
const NOTION_VERSION = "2026-03-11";
const MAX_BODY_BYTES = 16_384;
const MAX_TITLE_LENGTH = 120;
const MAX_MESSAGE_LENGTH = 5_000;
const MAX_EMAIL_LENGTH = 320;
const NOTION_RICH_TEXT_LIMIT = 2_000;

type FeedbackEnv = {
  NOTION_API_TOKEN?: string;
  NOTION_FEEDBACK_DATA_SOURCE_ID?: string;
};

type FeedbackKind = "request" | "feedback" | "bug";

export type FeedbackSubmission = {
  type: FeedbackKind;
  title: string;
  message: string;
  email?: string;
  appVersion?: string;
  osVersion?: string;
};

type Fetcher = (
  input: RequestInfo | URL,
  init?: RequestInit,
) => Promise<Response>;

export async function handleFeedbackRequest(
  request: Request,
  env: FeedbackEnv,
  fetcher: Fetcher = fetch,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== "/v2/feedback") return null;
  if (request.method !== "POST") {
    return response(
      { error: { code: "method_not_allowed", message: "Method not allowed." } },
      405,
      { Allow: "POST" },
    );
  }

  const token = env.NOTION_API_TOKEN?.trim();
  const dataSourceId = env.NOTION_FEEDBACK_DATA_SOURCE_ID?.trim();
  if (!token || !dataSourceId) {
    return response(
      {
        error: {
          code: "feedback_unavailable",
          message: "Feedback is temporarily unavailable.",
        },
      },
      503,
    );
  }

  const contentLength = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return invalid("Feedback payload is too large.", 413);
  }

  let submission: FeedbackSubmission;
  try {
    const raw = await request.text();
    if (new TextEncoder().encode(raw).byteLength > MAX_BODY_BYTES) {
      return invalid("Feedback payload is too large.", 413);
    }
    submission = parseSubmission(JSON.parse(raw));
  } catch (error) {
    return invalid(
      error instanceof Error ? error.message : "Invalid feedback payload.",
    );
  }

  try {
    const titleProperty = await retrieveTitleProperty(
      token,
      dataSourceId,
      fetcher,
    );
    const notionResponse = await fetcher(`${NOTION_API_BASE}/pages`, {
      method: "POST",
      headers: notionHeaders(token),
      body: JSON.stringify({
        parent: { type: "data_source_id", data_source_id: dataSourceId },
        icon: { type: "emoji", emoji: iconFor(submission.type) },
        properties: {
          [titleProperty]: {
            type: "title",
            title: richText(`[${labelFor(submission.type)}] ${submission.title}`),
          },
        },
        children: feedbackBlocks(submission),
      }),
    });
    if (!notionResponse.ok) {
      const detail = (await notionResponse.text()).slice(0, 1_000);
      console.error(JSON.stringify({
        level: "error",
        message: "Notion feedback page creation failed.",
        status: notionResponse.status,
        detail,
      }));
      return response(
        {
          error: {
            code: "feedback_delivery_failed",
            message: "Could not send feedback. Please try again.",
          },
        },
        502,
      );
    }
    return response({ ok: true }, 201);
  } catch (error) {
    console.error(JSON.stringify({
      level: "error",
      message: "Notion feedback delivery failed.",
      detail: error instanceof Error ? error.message : String(error),
    }));
    return response(
      {
        error: {
          code: "feedback_delivery_failed",
          message: "Could not send feedback. Please try again.",
        },
      },
      502,
    );
  }
}

export function parseSubmission(value: unknown): FeedbackSubmission {
  if (!isRecord(value)) throw new Error("Invalid feedback payload.");
  const type = value.type;
  if (type !== "request" && type !== "feedback" && type !== "bug") {
    throw new Error("Choose a valid feedback type.");
  }
  const title = boundedString(value.title, "Title", 1, MAX_TITLE_LENGTH);
  const message = boundedString(value.message, "Details", 1, MAX_MESSAGE_LENGTH);
  const email = optionalString(value.email, "Email", MAX_EMAIL_LENGTH);
  if (email && !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    throw new Error("Enter a valid email address.");
  }
  const appVersion = optionalString(value.appVersion, "App version", 100);
  const osVersion = optionalString(value.osVersion, "OS version", 200);
  return {
    type,
    title,
    message,
    ...(email ? { email } : {}),
    ...(appVersion ? { appVersion } : {}),
    ...(osVersion ? { osVersion } : {}),
  };
}

async function retrieveTitleProperty(
  token: string,
  dataSourceId: string,
  fetcher: Fetcher,
): Promise<string> {
  const result = await fetcher(
    `${NOTION_API_BASE}/data_sources/${encodeURIComponent(dataSourceId)}`,
    { headers: notionHeaders(token) },
  );
  if (!result.ok) {
    throw new Error(`Could not read Notion data source schema (${result.status}).`);
  }
  const body: unknown = await result.json();
  if (!isRecord(body) || !isRecord(body.properties)) {
    throw new Error("Notion returned an invalid data source schema.");
  }
  for (const [name, property] of Object.entries(body.properties)) {
    if (isRecord(property) && property.type === "title") return name;
  }
  throw new Error("Notion feedback data source has no title property.");
}

function feedbackBlocks(submission: FeedbackSubmission): Record<string, unknown>[] {
  const metadata = [
    `Type: ${labelFor(submission.type)}`,
    ...(submission.email ? [`Reply email: ${submission.email}`] : []),
    ...(submission.appVersion ? [`App version: ${submission.appVersion}`] : []),
    ...(submission.osVersion ? [`OS: ${submission.osVersion}`] : []),
    `Received: ${new Date().toISOString()}`,
  ];
  return [
    {
      object: "block",
      type: "callout",
      callout: {
        icon: { type: "emoji", emoji: iconFor(submission.type) },
        rich_text: richText(metadata.join("\n")),
        color: "orange_background",
      },
    },
    {
      object: "block",
      type: "heading_2",
      heading_2: { rich_text: richText("Details") },
    },
    ...chunks(submission.message, NOTION_RICH_TEXT_LIMIT).map((content) => ({
      object: "block",
      type: "paragraph",
      paragraph: { rich_text: richText(content) },
    })),
  ];
}

function notionHeaders(token: string): HeadersInit {
  return {
    Authorization: `Bearer ${token}`,
    "Content-Type": "application/json",
    "Notion-Version": NOTION_VERSION,
  };
}

function richText(content: string): Record<string, unknown>[] {
  return [{ type: "text", text: { content } }];
}

function chunks(value: string, length: number): string[] {
  const result: string[] = [];
  for (let offset = 0; offset < value.length; offset += length) {
    result.push(value.slice(offset, offset + length));
  }
  return result;
}

function iconFor(type: FeedbackKind): string {
  return type === "bug" ? "🐞" : type === "request" ? "✨" : "💬";
}

function labelFor(type: FeedbackKind): string {
  return type === "bug" ? "Bug" : type === "request" ? "Request" : "Feedback";
}

function boundedString(
  value: unknown,
  label: string,
  minimum: number,
  maximum: number,
): string {
  if (typeof value !== "string") throw new Error(`${label} is required.`);
  const trimmed = value.trim();
  if (trimmed.length < minimum) throw new Error(`${label} is required.`);
  if (trimmed.length > maximum) {
    throw new Error(`${label} must be ${maximum} characters or fewer.`);
  }
  return trimmed;
}

function optionalString(
  value: unknown,
  label: string,
  maximum: number,
): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  return boundedString(value, label, 1, maximum);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function invalid(message: string, status = 400): Response {
  return response({ error: { code: "invalid_feedback", message } }, status);
}

function response(
  body: Record<string, unknown>,
  status: number,
  extraHeaders?: HeadersInit,
): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Content-Type", "application/json; charset=utf-8");
  headers.set("Cache-Control", "no-store");
  return Response.json(body, { status, headers });
}
