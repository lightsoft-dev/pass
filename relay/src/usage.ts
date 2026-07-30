import {
  authenticateDeviceCredential,
  type AuthenticationResult,
  type CredentialIdentity,
} from "./auth";

const USAGE_PREFIX = "/v2/usage";
const MAX_BODY_BYTES = 128 * 1_024;
const MAX_ROWS = 100;
// 90 rows × four fields stay safely below Number.MAX_SAFE_INTEGER after aggregation.
const MAX_TOKEN_VALUE = 1_000_000_000_000;
const ALLOWED_PERIODS = new Set([7, 30]);
const ALLOWED_PROVIDERS = new Set(["claude", "codex", "pi"]);

type UsageEnv = Env & {
  DEVICE_CREDENTIAL_PEPPER?: string;
};

type JSONBody = Record<string, unknown>;

type UsageContext = {
  credential: CredentialIdentity;
};

type DailyUsage = {
  date: string;
  provider: "claude" | "codex" | "pi";
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheWriteTokens: number;
};

type RankingRow = {
  account_id: string;
  display_name: string;
  input_tokens: number;
  output_tokens: number;
  cache_read_tokens: number;
  cache_write_tokens: number;
  total_tokens: number;
  rank: number;
  updated_at: number;
};

export async function handleUsageRequest(
  request: Request,
  env: UsageEnv,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== USAGE_PREFIX && !url.pathname.startsWith(`${USAGE_PREFIX}/`)) {
    return null;
  }

  const context = await usageContext(request, env);
  if (context instanceof Response) return context;

  if (url.pathname === `${USAGE_PREFIX}/leaderboard`) {
    return request.method === "GET"
      ? handleLeaderboard(url, env, context)
      : methodNotAllowed("GET");
  }
  if (url.pathname === `${USAGE_PREFIX}/snapshots`) {
    if (request.method === "PUT") return handlePublish(request, env, context);
    if (request.method === "DELETE") return handleOptOut(env, context);
    return methodNotAllowed("PUT, DELETE");
  }
  return apiError(404, "not_found", "Usage route not found.");
}

async function usageContext(
  request: Request,
  env: UsageEnv,
): Promise<UsageContext | Response> {
  const authenticated = await authenticateDeviceCredential(request, env, "access");
  if (!authenticated.ok) return authenticationError(authenticated);
  if (authenticated.value.role !== "desktop" || authenticated.value.subjectType !== "desktop") {
    return apiError(403, "forbidden", "Only a registered desktop can use the usage leaderboard.");
  }
  return { credential: authenticated.value };
}

async function handlePublish(
  request: Request,
  env: UsageEnv,
  context: UsageContext,
): Promise<Response> {
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const days = parseDailyUsage(body.days);
  if (days instanceof Response) return days;

  const now = Date.now();
  const statements = [
    env.CONTROL_DB.prepare(
      `INSERT INTO usage_leaderboard_profiles (account_id, joined_at, updated_at)
       VALUES (?, ?, ?)
       ON CONFLICT(account_id) DO UPDATE SET updated_at = excluded.updated_at`,
    ).bind(context.credential.accountId, now, now),
    env.CONTROL_DB.prepare(
      "DELETE FROM usage_daily_totals WHERE account_id = ? AND desktop_id = ?",
    ).bind(context.credential.accountId, context.credential.desktopId),
  ];
  for (const day of days) {
    statements.push(
      env.CONTROL_DB.prepare(
        `INSERT INTO usage_daily_totals
          (account_id, desktop_id, usage_date, provider, input_tokens, output_tokens,
           cache_read_tokens, cache_write_tokens, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        context.credential.accountId,
        context.credential.desktopId,
        day.date,
        day.provider,
        day.inputTokens,
        day.outputTokens,
        day.cacheReadTokens,
        day.cacheWriteTokens,
        now,
      ),
    );
  }
  await env.CONTROL_DB.batch(statements);

  return apiResponse({
    sharing: true,
    publishedRows: days.length,
    updatedAt: new Date(now).toISOString(),
  });
}

async function handleOptOut(
  env: UsageEnv,
  context: UsageContext,
): Promise<Response> {
  const result = await env.CONTROL_DB.prepare(
    "DELETE FROM usage_leaderboard_profiles WHERE account_id = ?",
  ).bind(context.credential.accountId).run();
  return apiResponse({ sharing: false, removed: result.meta.changes > 0 });
}

async function handleLeaderboard(
  url: URL,
  env: UsageEnv,
  context: UsageContext,
): Promise<Response> {
  const query = parseLeaderboardQuery(url);
  if (query instanceof Response) return query;
  const cutoff = dateKey(Date.now() - (query.days - 1) * 24 * 60 * 60 * 1_000);
  const bindings = [cutoff];
  const cte = `
    WITH totals AS (
      SELECT
        p.account_id,
        COALESCE(NULLIF(TRIM(a.display_name), ''),
                 'Pass user ' || substr(p.account_id, -4)) AS display_name,
        COALESCE(SUM(u.input_tokens), 0) AS input_tokens,
        COALESCE(SUM(u.output_tokens), 0) AS output_tokens,
        COALESCE(SUM(u.cache_read_tokens), 0) AS cache_read_tokens,
        COALESCE(SUM(u.cache_write_tokens), 0) AS cache_write_tokens,
        COALESCE(SUM(
          u.input_tokens + u.output_tokens + u.cache_read_tokens + u.cache_write_tokens
        ), 0) AS total_tokens,
        p.updated_at
      FROM usage_leaderboard_profiles p
      JOIN accounts a ON a.id = p.account_id
      LEFT JOIN usage_daily_totals u
        ON u.account_id = p.account_id AND u.usage_date >= ?
      GROUP BY p.account_id, a.display_name, p.updated_at
    ),
    ranked AS (
      SELECT *,
             RANK() OVER (ORDER BY total_tokens DESC) AS rank
        FROM totals
       WHERE total_tokens > 0
    )`;

  const [page, me, profile] = await Promise.all([
    env.CONTROL_DB.prepare(
      `${cte}
       SELECT * FROM ranked ORDER BY rank ASC, account_id ASC LIMIT ?`,
    ).bind(...bindings, query.limit).all<RankingRow>(),
    env.CONTROL_DB.prepare(
      `${cte}
       SELECT * FROM ranked WHERE account_id = ?`,
    ).bind(...bindings, context.credential.accountId).first<RankingRow>(),
    env.CONTROL_DB.prepare(
      "SELECT updated_at FROM usage_leaderboard_profiles WHERE account_id = ?",
    ).bind(context.credential.accountId).first<{ updated_at: number }>(),
  ]);

  return apiResponse({
    periodDays: query.days,
    generatedAt: new Date().toISOString(),
    sharing: profile !== null,
    updatedAt: profile === null ? null : new Date(profile.updated_at).toISOString(),
    leaderboard: page.results.map((row) =>
      rankingDTO(row, row.account_id === context.credential.accountId)
    ),
    me: me === null ? null : rankingDTO(me, true),
  });
}

function rankingDTO(row: RankingRow, isMe: boolean): JSONBody {
  return {
    rank: row.rank,
    displayName: row.display_name,
    inputTokens: row.input_tokens,
    outputTokens: row.output_tokens,
    cacheReadTokens: row.cache_read_tokens,
    cacheWriteTokens: row.cache_write_tokens,
    totalTokens: row.total_tokens,
    isMe,
    updatedAt: new Date(row.updated_at).toISOString(),
  };
}

function parseLeaderboardQuery(
  url: URL,
): { days: number; limit: number } | Response {
  for (const key of url.searchParams.keys()) {
    if (key !== "days" && key !== "limit") {
      return apiError(400, "invalid_query", `Unsupported query parameter: ${key}.`);
    }
  }
  const days = parseInteger(url.searchParams.get("days") ?? "7");
  if (days === null || !ALLOWED_PERIODS.has(days)) {
    return apiError(400, "invalid_query", "days must be 7 or 30.");
  }
  const limit = parseInteger(url.searchParams.get("limit") ?? "50");
  if (limit === null || limit < 1 || limit > 100) {
    return apiError(400, "invalid_query", "limit must be between 1 and 100.");
  }
  return { days, limit };
}

function parseDailyUsage(value: unknown): DailyUsage[] | Response {
  if (!Array.isArray(value) || value.length > MAX_ROWS) {
    return apiError(400, "invalid_usage", `days must be an array with at most ${MAX_ROWS} rows.`);
  }
  const minimumDate = dateKey(Date.now() - 45 * 24 * 60 * 60 * 1_000);
  const maximumDate = dateKey(Date.now() + 24 * 60 * 60 * 1_000);
  const seen = new Set<string>();
  const allowedKeys = new Set([
    "date",
    "provider",
    "inputTokens",
    "outputTokens",
    "cacheReadTokens",
    "cacheWriteTokens",
  ]);
  const rows: DailyUsage[] = [];
  for (const raw of value) {
    if (!isRecord(raw)) {
      return apiError(400, "invalid_usage", "Each usage row must be an object.");
    }
    if (Object.keys(raw).some((key) => !allowedKeys.has(key))) {
      return apiError(
        400,
        "invalid_usage",
        "Usage rows may contain only aggregate token fields.",
      );
    }
    const date = typeof raw.date === "string" ? raw.date : "";
    const provider = typeof raw.provider === "string" ? raw.provider : "";
    if (!isDateKey(date) || date < minimumDate || date > maximumDate) {
      return apiError(400, "invalid_usage", "Usage dates must be within the last 45 days.");
    }
    if (!ALLOWED_PROVIDERS.has(provider)) {
      return apiError(400, "invalid_usage", "provider must be claude, codex, or pi.");
    }
    const key = `${date}\u0000${provider}`;
    if (seen.has(key)) {
      return apiError(400, "invalid_usage", "Usage rows must be unique by date and provider.");
    }
    seen.add(key);
    const tokens = [
      raw.inputTokens,
      raw.outputTokens,
      raw.cacheReadTokens,
      raw.cacheWriteTokens,
    ];
    if (tokens.some((token) =>
      typeof token !== "number" ||
      !Number.isSafeInteger(token) ||
      token < 0 ||
      token > MAX_TOKEN_VALUE
    )) {
      return apiError(400, "invalid_usage", "Token counts must be non-negative safe integers.");
    }
    rows.push({
      date,
      provider: provider as DailyUsage["provider"],
      inputTokens: raw.inputTokens as number,
      outputTokens: raw.outputTokens as number,
      cacheReadTokens: raw.cacheReadTokens as number,
      cacheWriteTokens: raw.cacheWriteTokens as number,
    });
  }
  return rows;
}

async function parseJSONBody(request: Request): Promise<JSONBody | Response> {
  const contentLength = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return apiError(413, "body_too_large", "Request body is too large.");
  }
  const data = await request.arrayBuffer();
  if (data.byteLength > MAX_BODY_BYTES) {
    return apiError(413, "body_too_large", "Request body is too large.");
  }
  try {
    const value: unknown = JSON.parse(new TextDecoder().decode(data));
    return isRecord(value)
      ? value
      : apiError(400, "invalid_json", "Request body must be a JSON object.");
  } catch {
    return apiError(400, "invalid_json", "Request body must be valid JSON.");
  }
}

function parseInteger(value: string): number | null {
  return /^(0|[1-9]\d*)$/.test(value) ? Number(value) : null;
}

function isDateKey(value: string): boolean {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(value)) return false;
  const date = new Date(`${value}T00:00:00.000Z`);
  return !Number.isNaN(date.valueOf()) && date.toISOString().slice(0, 10) === value;
}

function dateKey(timestamp: number): string {
  return new Date(timestamp).toISOString().slice(0, 10);
}

function isRecord(value: unknown): value is JSONBody {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function authenticationError(
  result: Extract<AuthenticationResult<CredentialIdentity>, { ok: false }>,
): Response {
  return apiError(result.status, result.code, result.message);
}

function methodNotAllowed(allow: string): Response {
  return apiError(405, "method_not_allowed", "Method not allowed.", { Allow: allow });
}

function apiResponse(body: JSONBody, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
    },
  });
}

function apiError(
  status: number,
  code: string,
  message: string,
  extraHeaders?: HeadersInit,
): Response {
  const headers = new Headers(extraHeaders);
  headers.set("Cache-Control", "no-store");
  headers.set("Content-Type", "application/json; charset=utf-8");
  return Response.json({ error: { code, message } }, { status, headers });
}
