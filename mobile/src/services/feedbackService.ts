export const CONTENT_REPORT_LIMITS = {
  sourceMessageID: 200,
  excerpt: 3_500,
  note: 800,
} as const;

const CONTENT_REPORT_TIMEOUT_MS = 15_000;

export const CONTENT_REPORT_REASONS = [
  "incorrect",
  "unsafe",
  "privacy",
  "inappropriate",
  "other",
] as const;

export type ContentReportReason = (typeof CONTENT_REPORT_REASONS)[number];

export const CONTENT_REPORT_REASON_LABELS: Record<ContentReportReason, string> = {
  incorrect: "Incorrect or misleading",
  unsafe: "Unsafe or harmful",
  privacy: "Privacy or security concern",
  inappropriate: "Offensive or inappropriate",
  other: "Something else",
};

export type ContentReportInput = {
  sourceMessageID: string;
  reason: ContentReportReason;
  excerpt: string;
  note?: string;
};

export type ContentReportResult = {
  reportId: string;
  delivery: "queued" | "delivered";
};

export type ContentReportSubmission = {
  type: "feedback";
  title: string;
  message: string;
};

type SubmitContentReportOptions = {
  fetchImpl?: typeof fetch;
  timeoutMilliseconds?: number;
};

export class ContentReportError extends Error {
  readonly code: string | null;
  readonly status: number | null;

  constructor(message: string, options: { code?: string | null; status?: number | null } = {}) {
    super(message);
    this.name = "ContentReportError";
    this.code = options.code ?? null;
    this.status = options.status ?? null;
  }
}

export function buildContentReportSubmission(
  input: ContentReportInput,
): ContentReportSubmission {
  if (!CONTENT_REPORT_REASONS.includes(input.reason)) {
    throw new ContentReportError("Choose why you are reporting this response.");
  }
  const sourceMessageID = requiredText(
    input.sourceMessageID,
    "Source message ID",
    CONTENT_REPORT_LIMITS.sourceMessageID,
  );
  if (/[\r\n\u0000-\u001f\u007f]/.test(sourceMessageID)) {
    throw new ContentReportError("The source message ID is invalid.");
  }
  const excerpt = requiredText(
    input.excerpt,
    "Response excerpt",
    CONTENT_REPORT_LIMITS.excerpt,
  );
  const note = optionalText(input.note, "Additional note", CONTENT_REPORT_LIMITS.note);
  const reason = CONTENT_REPORT_REASON_LABELS[input.reason];
  const sections = [
    `Reason: ${reason}`,
    `Source message ID: ${sourceMessageID}`,
    `Reported response:\n${excerpt}`,
  ];
  if (note) sections.push(`Additional note:\n${note}`);
  return {
    type: "feedback",
    title: `AI response report: ${reason}`,
    message: sections.join("\n\n"),
  };
}

export async function submitContentReport(
  relayBaseURL: string,
  input: ContentReportInput,
  options: SubmitContentReportOptions = {},
): Promise<ContentReportResult> {
  const endpoint = feedbackEndpoint(relayBaseURL);
  const submission = buildContentReportSubmission(input);
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    options.timeoutMilliseconds ?? CONTENT_REPORT_TIMEOUT_MS,
  );
  let response: Response;
  try {
    response = await (options.fetchImpl ?? fetch)(endpoint, {
      method: "POST",
      credentials: "omit",
      redirect: "error",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
      },
      body: JSON.stringify(submission),
      signal: controller.signal,
    });
  } catch {
    throw new ContentReportError(
      controller.signal.aborted
        ? "The report request timed out. Please try again."
        : "Could not reach Pass Relay. Check your connection and try again.",
    );
  } finally {
    clearTimeout(timeout);
  }

  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const apiError = parseAPIError(payload);
    throw new ContentReportError(
      response.status === 429
        ? "Too many reports were sent recently. Please wait a minute and try again."
        : apiError?.message ?? "The report could not be submitted. Please try again.",
      { code: apiError?.code, status: response.status },
    );
  }
  if (
    !isRecord(payload)
    || payload.ok !== true
    || typeof payload.reportId !== "string"
    || payload.reportId.length === 0
    || payload.reportId.length > 200
    || (payload.delivery !== "queued" && payload.delivery !== "delivered")
  ) {
    throw new ContentReportError("Pass Relay returned an invalid report response.");
  }
  return {
    reportId: payload.reportId,
    delivery: payload.delivery,
  };
}

function feedbackEndpoint(relayBaseURL: string): string {
  let url: URL;
  try {
    url = new URL(relayBaseURL.trim());
  } catch {
    throw new ContentReportError("Content reporting is unavailable in this build.");
  }
  const insecureLocalDevelopment =
    url.protocol === "http:"
    && (url.hostname === "localhost" || url.hostname === "127.0.0.1");
  if (
    (url.protocol !== "https:" && !insecureLocalDevelopment)
    || !url.hostname
    || url.username
    || url.password
  ) {
    throw new ContentReportError("Content reporting is unavailable in this build.");
  }
  url.search = "";
  url.hash = "";
  url.pathname = `${url.pathname.replace(/\/+$/, "")}/v2/feedback`;
  return url.toString();
}

function requiredText(value: unknown, label: string, maximum: number): string {
  if (typeof value !== "string" || !value.trim()) {
    throw new ContentReportError(`${label} is required.`);
  }
  const trimmed = value.trim();
  if (trimmed.length > maximum) {
    throw new ContentReportError(`${label} must be ${maximum} characters or fewer.`);
  }
  return trimmed;
}

function optionalText(
  value: unknown,
  label: string,
  maximum: number,
): string | undefined {
  if (value === undefined || value === null || value === "") return undefined;
  return requiredText(value, label, maximum);
}

function parseAPIError(payload: unknown): { code: string | null; message: string | null } | null {
  if (!isRecord(payload) || !isRecord(payload.error)) return null;
  const code = payload.error.code;
  const message = payload.error.message;
  return {
    code: typeof code === "string" && code.length <= 100 ? code : null,
    message: typeof message === "string" && message.length <= 500 ? message : null,
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
