import {
  authenticateDeviceCredential,
  compactUUID,
  type AuthenticationResult,
  type CredentialIdentity,
} from "./auth";

const MARKETPLACE_PREFIX = "/v2/marketplace/extensions";
const MAX_BODY_BYTES = 80 * 1_024;
const MAX_MANIFEST_BYTES = 64 * 1_024;
const DEFAULT_PAGE_SIZE = 20;
const MAX_PAGE_SIZE = 50;
const EXTENSION_ID_PATTERN = /^mkt_[a-f0-9]{32}$/;
const MANIFEST_ID_PATTERN = /^[a-z0-9][a-z0-9-]{0,99}$/;
const CATEGORY_PATTERN = /^[a-z0-9][a-z0-9-]{0,39}$/;
const TAG_PATTERN = /^[a-z0-9][a-z0-9-]{0,31}$/;
const SEMVER_PATTERN = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$/;

type MarketplaceEnv = Env & {
  DEVICE_CREDENTIAL_PEPPER?: string;
  MARKETPLACE_ADMIN_ACCOUNT_IDS?: string;
};

type JSONBody = Record<string, unknown>;
type MarketplaceContext = {
  credential: CredentialIdentity;
  isAdmin: boolean;
};

type ExtensionRow = {
  id: string;
  owner_account_id: string;
  owner_display_name: string | null;
  manifest_id: string;
  repository_url: string;
  name: string;
  summary: string;
  description: string | null;
  category: string | null;
  tags_json: string;
  version: string;
  manifest_json: string;
  install_count: number;
  report_count: number;
  created_at: number;
  updated_at: number;
  hidden_at: number | null;
};

type ExtensionInput = {
  repositoryUrl: string;
  name: string;
  summary: string;
  description: string | null;
  category: string | null;
  tags: string[];
  version: string;
  manifest: JSONBody;
  manifestId: string;
};

type Cursor = { updatedAt: number; id: string };
type ReportReason = "malware" | "spam" | "misleading" | "copyright" | "other";

export async function handleMarketplaceRequest(
  request: Request,
  env: MarketplaceEnv,
): Promise<Response | null> {
  const url = new URL(request.url);
  if (url.pathname !== MARKETPLACE_PREFIX && !url.pathname.startsWith(`${MARKETPLACE_PREFIX}/`)) {
    return null;
  }

  const context = await marketplaceContext(request, env);
  if (context instanceof Response) return context;

  if (url.pathname === MARKETPLACE_PREFIX) {
    if (request.method === "GET") return handleList(url, env, context);
    if (request.method === "POST") return handleCreate(request, env, context);
    return methodNotAllowed("GET, POST");
  }

  const route = new RegExp(
    `^${MARKETPLACE_PREFIX}/(mkt_[a-f0-9]{32})(?:/(install|reports|moderation))?$`,
  ).exec(url.pathname);
  const extensionId = route?.[1];
  const action = route?.[2];
  if (!extensionId) return apiError(404, "not_found", "Marketplace route not found.");

  if (action === "install") {
    return request.method === "POST"
      ? handleInstall(env, context, extensionId)
      : methodNotAllowed("POST");
  }
  if (action === "reports") {
    return request.method === "POST"
      ? handleReport(request, env, context, extensionId)
      : methodNotAllowed("POST");
  }
  if (action === "moderation") {
    return request.method === "PATCH"
      ? handleModeration(request, env, context, extensionId)
      : methodNotAllowed("PATCH");
  }
  if (request.method === "GET") return handleDetail(env, context, extensionId);
  if (request.method === "PATCH") return handleUpdate(request, env, context, extensionId);
  if (request.method === "DELETE") return handleDelete(env, context, extensionId);
  return methodNotAllowed("GET, PATCH, DELETE");
}

async function marketplaceContext(
  request: Request,
  env: MarketplaceEnv,
): Promise<MarketplaceContext | Response> {
  const authenticated = await authenticateDeviceCredential(request, env, "access");
  if (!authenticated.ok) return authenticationError(authenticated);
  if (authenticated.value.role !== "desktop" || authenticated.value.subjectType !== "desktop") {
    return apiError(403, "forbidden", "Only a registered desktop can access the marketplace.");
  }
  return {
    credential: authenticated.value,
    isAdmin: adminAccountIDs(env).has(authenticated.value.accountId),
  };
}

async function handleList(
  url: URL,
  env: MarketplaceEnv,
  context: MarketplaceContext,
): Promise<Response> {
  const parsed = parseListQuery(url);
  if (parsed instanceof Response) return parsed;

  const where = ["e.deleted_at IS NULL"];
  const bindings: unknown[] = [];
  if (parsed.owner === "me") {
    where.push("e.owner_account_id = ?");
    bindings.push(context.credential.accountId);
  } else if (!context.isAdmin) {
    where.push("e.hidden_at IS NULL");
  }
  if (parsed.q !== null) {
    const pattern = `%${escapeLike(parsed.q)}%`;
    where.push(`(
      e.name LIKE ? ESCAPE '\\' COLLATE NOCASE OR
      e.summary LIKE ? ESCAPE '\\' COLLATE NOCASE OR
      COALESCE(e.description, '') LIKE ? ESCAPE '\\' COLLATE NOCASE OR
      e.manifest_id LIKE ? ESCAPE '\\' COLLATE NOCASE OR
      e.tags_json LIKE ? ESCAPE '\\' COLLATE NOCASE
    )`);
    bindings.push(pattern, pattern, pattern, pattern, pattern);
  }
  if (parsed.category !== null) {
    where.push("e.category = ? COLLATE NOCASE");
    bindings.push(parsed.category);
  }
  if (parsed.cursor !== null) {
    where.push("(e.updated_at < ? OR (e.updated_at = ? AND e.id > ?))");
    bindings.push(parsed.cursor.updatedAt, parsed.cursor.updatedAt, parsed.cursor.id);
  }

  bindings.push(parsed.limit + 1);
  const rows = await env.CONTROL_DB.prepare(
    `${extensionSelect()}
      WHERE ${where.join(" AND ")}
      ORDER BY e.updated_at DESC, e.id ASC
      LIMIT ?`,
  ).bind(...bindings).all<ExtensionRow>();
  const page = rows.results.slice(0, parsed.limit);
  const last = page.at(-1);
  return apiResponse({
    extensions: page.map((row) => extensionDTO(row, context)),
    nextCursor: rows.results.length > parsed.limit && last
      ? encodeCursor({ updatedAt: last.updated_at, id: last.id })
      : null,
  });
}

async function handleDetail(
  env: MarketplaceEnv,
  context: MarketplaceContext,
  extensionId: string,
): Promise<Response> {
  const row = await findExtension(env.CONTROL_DB, extensionId);
  if (!canRead(row, context)) return apiError(404, "not_found", "Extension not found.");
  return apiResponse({ extension: extensionDTO(row, context) });
}

async function handleCreate(
  request: Request,
  env: MarketplaceEnv,
  context: MarketplaceContext,
): Promise<Response> {
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const input = parseCreateInput(body);
  if (input instanceof Response) return input;
  const conflict = await findConflict(env.CONTROL_DB, input);
  if (conflict !== null) return conflictResponse(conflict);

  const id = `mkt_${compactUUID()}`;
  const now = Date.now();
  try {
    await env.CONTROL_DB.batch([
      env.CONTROL_DB.prepare(
        `INSERT INTO marketplace_extensions
          (id, owner_account_id, manifest_id, repository_url, name, summary,
           description, category, tags_json, version, manifest_json, created_at, updated_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      ).bind(
        id,
        context.credential.accountId,
        input.manifestId,
        input.repositoryUrl,
        input.name,
        input.summary,
        input.description,
        input.category,
        JSON.stringify(input.tags),
        input.version,
        JSON.stringify(input.manifest),
        now,
        now,
      ),
      auditInsert(
        env.CONTROL_DB,
        context,
        "marketplace.extension.create",
        "marketplace_extension",
        id,
        now,
      ),
    ]);
  } catch (error) {
    if (isUniqueConstraintError(error)) {
      const racedConflict = await findConflict(env.CONTROL_DB, input);
      return conflictResponse(racedConflict ?? "repository");
    }
    throw error;
  }
  const row = await findExtension(env.CONTROL_DB, id);
  if (row === null) return apiError(500, "internal_error", "Extension could not be loaded.");
  return apiResponse({ extension: extensionDTO(row, context) }, 201);
}

async function handleUpdate(
  request: Request,
  env: MarketplaceEnv,
  context: MarketplaceContext,
  extensionId: string,
): Promise<Response> {
  const existing = await findExtension(env.CONTROL_DB, extensionId);
  if (existing === null) {
    return apiError(404, "not_found", "Extension not found.");
  }
  if (existing.owner_account_id !== context.credential.accountId) {
    return apiError(403, "forbidden", "Only the owner can update this extension.");
  }
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const input = parseUpdateInput(body, existing);
  if (input instanceof Response) return input;
  if (input.repositoryUrl !== existing.repository_url) {
    return apiError(
      409,
      "repository_immutable",
      "repositoryUrl cannot be changed after an extension is published.",
    );
  }
  if (input.manifestId !== existing.manifest_id) {
    return apiError(
      409,
      "manifest_id_immutable",
      "manifest.id cannot be changed after an extension is published.",
    );
  }
  const conflict = await findConflict(env.CONTROL_DB, input, extensionId);
  if (conflict !== null) return conflictResponse(conflict);

  const now = Date.now();
  let updateChanges = 0;
  try {
    const results = await env.CONTROL_DB.batch([
      env.CONTROL_DB.prepare(
        `UPDATE marketplace_extensions
            SET manifest_id = ?, repository_url = ?, name = ?, summary = ?, description = ?,
                category = ?, tags_json = ?, version = ?, manifest_json = ?, updated_at = ?
          WHERE id = ? AND owner_account_id = ? AND deleted_at IS NULL`,
      ).bind(
        input.manifestId,
        input.repositoryUrl,
        input.name,
        input.summary,
        input.description,
        input.category,
        JSON.stringify(input.tags),
        input.version,
        JSON.stringify(input.manifest),
        now,
        extensionId,
        context.credential.accountId,
      ),
      conditionalAuditInsert(
        env.CONTROL_DB,
        context,
        "marketplace.extension.update",
        "marketplace_extension",
        extensionId,
        now,
      ),
    ]);
    updateChanges = changes(results[0]);
  } catch (error) {
    if (isUniqueConstraintError(error)) {
      const racedConflict = await findConflict(env.CONTROL_DB, input, extensionId);
      return conflictResponse(racedConflict ?? "repository");
    }
    throw error;
  }
  if (updateChanges === 0) {
    return apiError(404, "not_found", "Extension not found.");
  }
  const row = await findExtension(env.CONTROL_DB, extensionId);
  if (row === null) return apiError(500, "internal_error", "Extension could not be loaded.");
  return apiResponse({ extension: extensionDTO(row, context) });
}

async function handleDelete(
  env: MarketplaceEnv,
  context: MarketplaceContext,
  extensionId: string,
): Promise<Response> {
  const now = Date.now();
  const results = await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      `UPDATE marketplace_extensions
          SET deleted_at = ?, updated_at = ?
        WHERE id = ? AND deleted_at IS NULL
          AND (owner_account_id = ? OR ? = 1)`,
    ).bind(
      now,
      now,
      extensionId,
      context.credential.accountId,
      context.isAdmin ? 1 : 0,
    ),
    conditionalAuditInsert(
      env.CONTROL_DB,
      context,
      "marketplace.extension.delete",
      "marketplace_extension",
      extensionId,
      now,
    ),
  ]);
  if (changes(results[0]) === 0) {
    const existing = await findExtension(env.CONTROL_DB, extensionId);
    return existing === null
      ? apiError(404, "not_found", "Extension not found.")
      : apiError(
          403,
          "forbidden",
          "Only the owner or a marketplace administrator can delete this extension.",
        );
  }
  return apiResponse({ deleted: true, extensionId });
}

async function handleInstall(
  env: MarketplaceEnv,
  context: MarketplaceContext,
  extensionId: string,
): Promise<Response> {
  const row = await findExtension(env.CONTROL_DB, extensionId);
  if (!canRead(row, context)) return apiError(404, "not_found", "Extension not found.");
  const now = Date.now();
  const results = await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      `INSERT OR IGNORE INTO marketplace_extension_installs
        (extension_id, account_id, installed_at) VALUES (?, ?, ?)`,
    ).bind(extensionId, context.credential.accountId, now),
    conditionalAuditInsert(
      env.CONTROL_DB,
      context,
      "marketplace.extension.install",
      "marketplace_extension",
      extensionId,
      now,
    ),
    env.CONTROL_DB.prepare(
      `UPDATE marketplace_extensions
          SET install_count = (
            SELECT COUNT(*) FROM marketplace_extension_installs WHERE extension_id = ?
          )
        WHERE id = ?`,
    ).bind(extensionId, extensionId),
  ]);
  const counted = changes(results[0]) === 1;
  const count = await env.CONTROL_DB.prepare(
    "SELECT install_count FROM marketplace_extensions WHERE id = ?",
  ).bind(extensionId).first<{ install_count: number }>();
  return apiResponse({ counted, installCount: count?.install_count ?? row.install_count });
}

async function handleReport(
  request: Request,
  env: MarketplaceEnv,
  context: MarketplaceContext,
  extensionId: string,
): Promise<Response> {
  const extension = await findExtension(env.CONTROL_DB, extensionId);
  if (!canRead(extension, context)) return apiError(404, "not_found", "Extension not found.");
  if (extension.owner_account_id === context.credential.accountId) {
    return apiError(409, "owner_report", "Owners cannot report their own extension.");
  }
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const unknown = unknownKeys(body, ["reason", "details"]);
  if (unknown.length > 0) return unknownFields(unknown);
  const reason = parseReportReason(body.reason);
  const details = optionalString(body, "details", 2_000);
  if (reason === null || details instanceof Response) {
    return details instanceof Response
      ? details
      : apiError(400, "invalid_request", "A valid report reason is required.");
  }
  const now = Date.now();
  const reportId = `report_${compactUUID()}`;
  const existingReport = await env.CONTROL_DB.prepare(
    `SELECT id FROM marketplace_extension_reports
      WHERE extension_id = ? AND reporter_account_id = ?`,
  ).bind(extensionId, context.credential.accountId).first<{ id: string }>();
  await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      `INSERT INTO marketplace_extension_reports
        (id, extension_id, reporter_account_id, reason, details, created_at, updated_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)
       ON CONFLICT(extension_id, reporter_account_id) DO UPDATE SET
         reason = excluded.reason,
         details = excluded.details,
         updated_at = excluded.updated_at,
         resolved_at = NULL`,
    ).bind(
      reportId,
      extensionId,
      context.credential.accountId,
      reason,
      details,
      now,
      now,
    ),
    auditInsert(
      env.CONTROL_DB,
      context,
      "marketplace.extension.report",
      "marketplace_extension",
      extensionId,
      now,
    ),
  ]);
  const report = await env.CONTROL_DB.prepare(
    `SELECT reason, created_at, updated_at FROM marketplace_extension_reports
      WHERE extension_id = ? AND reporter_account_id = ?`,
  ).bind(extensionId, context.credential.accountId).first<{
    reason: ReportReason;
    created_at: number;
    updated_at: number;
  }>();
  if (report === null) return apiError(500, "internal_error", "Report could not be loaded.");
  return apiResponse({
    report: {
      extensionId,
      reason: report.reason,
      createdAt: isoDate(report.created_at),
      updatedAt: isoDate(report.updated_at),
    },
  }, existingReport === null ? 201 : 200);
}

async function handleModeration(
  request: Request,
  env: MarketplaceEnv,
  context: MarketplaceContext,
  extensionId: string,
): Promise<Response> {
  if (!context.isAdmin) return apiError(403, "forbidden", "Marketplace administrator access is required.");
  const body = await parseJSONBody(request);
  if (body instanceof Response) return body;
  const unknown = unknownKeys(body, ["hidden"]);
  if (unknown.length > 0) return unknownFields(unknown);
  if (typeof body.hidden !== "boolean") {
    return apiError(400, "invalid_request", "hidden must be a boolean.");
  }
  const now = Date.now();
  const desiredHidden = body.hidden ? 1 : 0;
  await env.CONTROL_DB.batch([
    env.CONTROL_DB.prepare(
      `UPDATE marketplace_extensions
          SET hidden_at = ?, hidden_by_account_id = ?, updated_at = ?
        WHERE id = ? AND deleted_at IS NULL
          AND (hidden_at IS NULL) = ?`,
    ).bind(
      body.hidden ? now : null,
      body.hidden ? context.credential.accountId : null,
      now,
      extensionId,
      desiredHidden,
    ),
    conditionalAuditInsert(
      env.CONTROL_DB,
      context,
      body.hidden ? "marketplace.extension.hide" : "marketplace.extension.unhide",
      "marketplace_extension",
      extensionId,
      now,
    ),
  ]);
  const row = await findExtension(env.CONTROL_DB, extensionId);
  if (row === null) return apiError(404, "not_found", "Extension not found.");
  return apiResponse({ extension: extensionDTO(row, context) });
}

function parseCreateInput(body: JSONBody): ExtensionInput | Response {
  const unknown = unknownKeys(body, [
    "repositoryUrl",
    "name",
    "summary",
    "description",
    "category",
    "tags",
    "version",
    "manifest",
  ]);
  if (unknown.length > 0) return unknownFields(unknown);
  const repositoryUrl = parseRepositoryURL(body.repositoryUrl);
  const name = requiredString(body.name, "name", 120);
  const summary = requiredString(body.summary, "summary", 280);
  const description = optionalString(body, "description", 5_000);
  const category = parseCategory(body.category);
  const tags = parseTags(body.tags);
  const version = parseVersion(body.version);
  const manifest = parseManifest(body.manifest);
  const invalid = firstResponse([
    repositoryUrl,
    name,
    summary,
    description,
    category,
    tags,
    version,
    manifest,
  ]);
  if (invalid !== null) return invalid;
  return validateInput({
    repositoryUrl: repositoryUrl as string,
    name: name as string,
    summary: summary as string,
    description: description as string | null,
    category: category as string | null,
    tags: tags as string[],
    version: version as string,
    manifest: manifest as JSONBody,
    manifestId: "",
  });
}

function parseUpdateInput(body: JSONBody, existing: ExtensionRow): ExtensionInput | Response {
  const allowed = [
    "repositoryUrl",
    "name",
    "summary",
    "description",
    "category",
    "tags",
    "version",
    "manifest",
  ];
  const unknown = unknownKeys(body, allowed);
  if (unknown.length > 0) return unknownFields(unknown);
  if (!allowed.some((key) => hasOwn(body, key))) {
    return apiError(400, "invalid_request", "At least one update field is required.");
  }
  const currentManifest = parseStoredObject(existing.manifest_json);
  const currentTags = parseStoredStringArray(existing.tags_json);
  if (currentManifest === null || currentTags === null) {
    return apiError(500, "internal_error", "Stored extension metadata is invalid.");
  }
  const candidate = {
    repositoryUrl: hasOwn(body, "repositoryUrl")
      ? parseRepositoryURL(body.repositoryUrl)
      : existing.repository_url,
    name: hasOwn(body, "name") ? requiredString(body.name, "name", 120) : existing.name,
    summary: hasOwn(body, "summary")
      ? requiredString(body.summary, "summary", 280)
      : existing.summary,
    description: hasOwn(body, "description")
      ? optionalString(body, "description", 5_000)
      : existing.description,
    category: hasOwn(body, "category") ? parseCategory(body.category) : existing.category,
    tags: hasOwn(body, "tags") ? parseTags(body.tags) : currentTags,
    version: hasOwn(body, "version") ? parseVersion(body.version) : existing.version,
    manifest: hasOwn(body, "manifest") ? parseManifest(body.manifest) : currentManifest,
  };
  const invalid = firstResponse(Object.values(candidate));
  if (invalid !== null) return invalid;
  return validateInput({
    repositoryUrl: candidate.repositoryUrl as string,
    name: candidate.name as string,
    summary: candidate.summary as string,
    description: candidate.description as string | null,
    category: candidate.category as string | null,
    tags: candidate.tags as string[],
    version: candidate.version as string,
    manifest: candidate.manifest as JSONBody,
    manifestId: "",
  });
}

function validateInput(input: ExtensionInput): ExtensionInput | Response {
  const structuralProblem = manifestStructureProblem(input.manifest);
  if (structuralProblem !== null) {
    return apiError(400, "invalid_manifest", structuralProblem);
  }
  const manifestId = input.manifest.id as string;
  if (!MANIFEST_ID_PATTERN.test(manifestId)) {
    return apiError(
      400,
      "invalid_manifest",
      "manifest.id must contain only lowercase letters, digits, and hyphens.",
    );
  }
  if (input.manifest.apiVersion !== 1 && input.manifest.apiVersion !== 2) {
    return apiError(400, "invalid_manifest", "manifest.apiVersion must be 1 or 2.");
  }
  if (input.manifest.name !== input.name) {
    return apiError(400, "manifest_mismatch", "manifest.name must match name.");
  }
  if (input.manifest.version !== input.version) {
    return apiError(400, "manifest_mismatch", "manifest.version must match version.");
  }
  const permissions = input.manifest.permissions;
  if (
    permissions !== undefined && permissions !== null &&
    (!Array.isArray(permissions) ||
      permissions.length > 32 ||
      permissions.some((permission) =>
        typeof permission !== "string" || permission.length === 0 || permission.length > 128
      ))
  ) {
    return apiError(400, "invalid_manifest", "manifest.permissions must be a bounded string array.");
  }
  return { ...input, manifestId };
}

/**
 * Mirrors the synthesized Codable shape of Swift's ExtensionManifest. Semantic checks such as
 * permission/action compatibility remain the desktop runtime's trust boundary, but malformed JSON
 * must never enter D1 and later make an otherwise valid catalog page undecodable.
 */
function manifestStructureProblem(manifest: JSONBody): string | null {
  if (!Number.isSafeInteger(manifest.apiVersion)) {
    return "manifest.apiVersion must be an integer.";
  }
  if (typeof manifest.id !== "string") return "manifest.id must be a string.";
  if (typeof manifest.name !== "string") return "manifest.name must be a string.";
  const versionProblem = optionalStringShapeProblem(manifest.version, "manifest.version");
  if (versionProblem !== null) return versionProblem;
  const descriptionProblem = optionalStringShapeProblem(
    manifest.description,
    "manifest.description",
  );
  if (descriptionProblem !== null) return descriptionProblem;
  const permissionsProblem = optionalStringArrayShapeProblem(
    manifest.permissions,
    "manifest.permissions",
  );
  if (permissionsProblem !== null) return permissionsProblem;

  const contributes = manifest.contributes;
  if (contributes === undefined || contributes === null) return null;
  if (!isRecord(contributes)) return "manifest.contributes must be an object or null.";

  const commandsProblem = optionalObjectArrayShapeProblem(
    contributes.commands,
    "manifest.contributes.commands",
    commandStructureProblem,
  );
  if (commandsProblem !== null) return commandsProblem;
  const rulesProblem = optionalObjectArrayShapeProblem(
    contributes.rules,
    "manifest.contributes.rules",
    ruleStructureProblem,
  );
  if (rulesProblem !== null) return rulesProblem;
  const windowsProblem = optionalObjectArrayShapeProblem(
    contributes.windows,
    "manifest.contributes.windows",
    windowStructureProblem,
  );
  if (windowsProblem !== null) return windowsProblem;

  const actions = contributes.actions;
  if (actions !== undefined && actions !== null) {
    if (!isRecord(actions)) return "manifest.contributes.actions must be an object or null.";
    for (const [actionId, action] of Object.entries(actions)) {
      if (!isRecord(action)) {
        return `manifest.contributes.actions.${actionId} must be an object.`;
      }
      const problem = actionStructureProblem(
        action,
        `manifest.contributes.actions.${actionId}`,
      );
      if (problem !== null) return problem;
    }
  }
  return null;
}

function commandStructureProblem(command: JSONBody, path: string): string | null {
  if (typeof command.id !== "string") return `${path}.id must be a string.`;
  if (typeof command.title !== "string") return `${path}.title must be a string.`;
  const contextProblem = optionalStringShapeProblem(command.context, `${path}.context`);
  if (contextProblem !== null) return contextProblem;
  if (!isRecord(command.run)) return `${path}.run must be an object.`;
  return actionStructureProblem(command.run, `${path}.run`);
}

function ruleStructureProblem(rule: JSONBody, path: string): string | null {
  if (typeof rule.on !== "string") return `${path}.on must be a string.`;
  const filter = rule.if;
  if (filter !== undefined && filter !== null) {
    if (!isRecord(filter)) return `${path}.if must be an object or null.`;
    const kindProblem = optionalStringArrayShapeProblem(filter.kind, `${path}.if.kind`);
    if (kindProblem !== null) return kindProblem;
  }
  if (!isRecord(rule.run)) return `${path}.run must be an object.`;
  return actionStructureProblem(rule.run, `${path}.run`);
}

function windowStructureProblem(window: JSONBody, path: string): string | null {
  if (typeof window.id !== "string") return `${path}.id must be a string.`;
  if (typeof window.title !== "string") return `${path}.title must be a string.`;
  if (typeof window.entry !== "string") return `${path}.entry must be a string.`;
  const widthProblem = optionalFiniteNumberShapeProblem(window.width, `${path}.width`);
  if (widthProblem !== null) return widthProblem;
  const heightProblem = optionalFiniteNumberShapeProblem(window.height, `${path}.height`);
  if (heightProblem !== null) return heightProblem;
  return optionalStringArrayShapeProblem(window.subscriptions, `${path}.subscriptions`);
}

function actionStructureProblem(action: JSONBody, path: string): string | null {
  for (const field of ["script", "sendText", "openURL", "openWindow"] as const) {
    const problem = optionalStringShapeProblem(action[field], `${path}.${field}`);
    if (problem !== null) return problem;
  }
  const argsProblem = optionalStringArrayShapeProblem(action.args, `${path}.args`);
  if (argsProblem !== null) return argsProblem;
  if (
    action.timeoutSeconds !== undefined &&
    action.timeoutSeconds !== null &&
    !Number.isSafeInteger(action.timeoutSeconds)
  ) {
    return `${path}.timeoutSeconds must be an integer or null.`;
  }
  if (
    action.terminal !== undefined &&
    action.terminal !== null &&
    typeof action.terminal !== "boolean"
  ) {
    return `${path}.terminal must be a boolean or null.`;
  }
  const notify = action.notify;
  if (notify !== undefined && notify !== null) {
    if (!isRecord(notify)) return `${path}.notify must be an object or null.`;
    if (typeof notify.title !== "string") return `${path}.notify.title must be a string.`;
    const bodyProblem = optionalStringShapeProblem(notify.body, `${path}.notify.body`);
    if (bodyProblem !== null) return bodyProblem;
  }
  return null;
}

function optionalObjectArrayShapeProblem(
  value: unknown,
  path: string,
  validate: (object: JSONBody, path: string) => string | null,
): string | null {
  if (value === undefined || value === null) return null;
  if (!Array.isArray(value)) return `${path} must be an array or null.`;
  for (let index = 0; index < value.length; index += 1) {
    const item = value[index];
    if (!isRecord(item)) return `${path}[${index}] must be an object.`;
    const problem = validate(item, `${path}[${index}]`);
    if (problem !== null) return problem;
  }
  return null;
}

function optionalStringShapeProblem(value: unknown, path: string): string | null {
  return value === undefined || value === null || typeof value === "string"
    ? null
    : `${path} must be a string or null.`;
}

function optionalStringArrayShapeProblem(value: unknown, path: string): string | null {
  if (value === undefined || value === null) return null;
  return Array.isArray(value) && value.every((item) => typeof item === "string")
    ? null
    : `${path} must be an array of strings or null.`;
}

function optionalFiniteNumberShapeProblem(value: unknown, path: string): string | null {
  return value === undefined || value === null ||
      (typeof value === "number" && Number.isFinite(value))
    ? null
    : `${path} must be a finite number or null.`;
}

function parseRepositoryURL(value: unknown): string | Response {
  if (typeof value !== "string") {
    return apiError(400, "invalid_request", "repositoryUrl is required.");
  }
  const trimmed = value.trim();
  if (trimmed.length === 0 || trimmed.length > 2_048) {
    return apiError(400, "invalid_request", "repositoryUrl must be between 1 and 2048 characters.");
  }
  try {
    const url = new URL(trimmed);
    if (
      url.protocol !== "https:" ||
      url.username !== "" ||
      url.password !== "" ||
      url.port !== "" ||
      url.search !== "" ||
      url.hash !== "" ||
      url.pathname === "/" ||
      isLocalHostname(url.hostname)
    ) {
      throw new Error();
    }
    url.pathname = url.pathname.replace(/\/+$/, "");
    return url.toString();
  } catch {
    return apiError(
      400,
      "invalid_repository_url",
      "repositoryUrl must be a public HTTPS repository URL without credentials, query, or fragment.",
    );
  }
}

function parseManifest(value: unknown): JSONBody | Response {
  if (!isRecord(value)) {
    return apiError(400, "invalid_manifest", "manifest must be a JSON object.");
  }
  const encoded = JSON.stringify(value);
  if (new TextEncoder().encode(encoded).byteLength > MAX_MANIFEST_BYTES) {
    return apiError(413, "manifest_too_large", "manifest must not exceed 64 KiB.");
  }
  return value;
}

function parseVersion(value: unknown): string | Response {
  const version = requiredString(value, "version", 64);
  if (version instanceof Response) return version;
  return SEMVER_PATTERN.test(version)
    ? version
    : apiError(400, "invalid_version", "version must be a valid semantic version.");
}

function parseCategory(value: unknown): string | null | Response {
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    return apiError(400, "invalid_category", "category must be a lowercase slug or null.");
  }
  const normalized = value.trim().toLowerCase();
  return CATEGORY_PATTERN.test(normalized)
    ? normalized
    : apiError(400, "invalid_category", "category must be a lowercase slug or null.");
}

function parseTags(value: unknown): string[] | Response {
  if (value === undefined) return [];
  if (!Array.isArray(value) || value.length > 10) {
    return apiError(400, "invalid_tags", "tags must contain at most 10 lowercase slugs.");
  }
  const tags: string[] = [];
  for (const candidate of value) {
    if (typeof candidate !== "string") {
      return apiError(400, "invalid_tags", "tags must contain at most 10 lowercase slugs.");
    }
    const tag = candidate.trim().toLowerCase();
    if (!TAG_PATTERN.test(tag)) {
      return apiError(400, "invalid_tags", "tags must contain at most 10 lowercase slugs.");
    }
    if (!tags.includes(tag)) tags.push(tag);
  }
  return tags;
}

function parseReportReason(value: unknown): ReportReason | null {
  return value === "malware" ||
    value === "spam" ||
    value === "misleading" ||
    value === "copyright" ||
    value === "other"
    ? value
    : null;
}

function parseListQuery(url: URL): {
  q: string | null;
  category: string | null;
  owner: "me" | null;
  limit: number;
  cursor: Cursor | null;
} | Response {
  const supported = new Set(["q", "category", "owner", "limit", "cursor"]);
  for (const key of url.searchParams.keys()) {
    if (!supported.has(key)) return apiError(400, "invalid_query", `Unsupported query parameter: ${key}.`);
  }
  const rawQ = url.searchParams.get("q")?.trim() ?? "";
  if (rawQ.length > 100) return apiError(400, "invalid_query", "q must not exceed 100 characters.");
  const rawCategory = url.searchParams.get("category");
  const category = rawCategory === null ? null : parseCategory(rawCategory);
  if (category instanceof Response) return category;
  const rawOwner = url.searchParams.get("owner");
  if (rawOwner !== null && rawOwner !== "me") {
    return apiError(400, "invalid_query", "owner must be me when provided.");
  }
  const rawLimit = url.searchParams.get("limit");
  const limit = rawLimit === null ? DEFAULT_PAGE_SIZE : Number(rawLimit);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > MAX_PAGE_SIZE) {
    return apiError(400, "invalid_query", `limit must be between 1 and ${MAX_PAGE_SIZE}.`);
  }
  const rawCursor = url.searchParams.get("cursor");
  const cursor = rawCursor === null ? null : decodeCursor(rawCursor);
  if (rawCursor !== null && cursor === null) {
    return apiError(400, "invalid_cursor", "cursor is invalid.");
  }
  return {
    q: rawQ.length === 0 ? null : rawQ,
    category: category as string | null,
    owner: rawOwner as "me" | null,
    limit,
    cursor,
  };
}

async function findExtension(db: D1Database, id: string): Promise<ExtensionRow | null> {
  if (!EXTENSION_ID_PATTERN.test(id)) return null;
  return db.prepare(
    `${extensionSelect()} WHERE e.id = ? AND e.deleted_at IS NULL`,
  ).bind(id).first<ExtensionRow>();
}

async function findConflict(
  db: D1Database,
  input: ExtensionInput,
  excludingId?: string,
): Promise<"repository" | "manifest" | null> {
  const row = await db.prepare(
    `SELECT repository_url, manifest_id
       FROM marketplace_extensions
      WHERE deleted_at IS NULL
        AND (? IS NULL OR id <> ?)
        AND (repository_url = ? COLLATE NOCASE OR manifest_id = ? COLLATE NOCASE)
      LIMIT 1`,
  ).bind(
    excludingId ?? null,
    excludingId ?? null,
    input.repositoryUrl,
    input.manifestId,
  ).first<{ repository_url: string; manifest_id: string }>();
  if (row === null) return null;
  return row.repository_url.toLowerCase() === input.repositoryUrl.toLowerCase()
    ? "repository"
    : "manifest";
}

function extensionSelect(): string {
  return `SELECT e.id, e.owner_account_id, a.display_name AS owner_display_name,
                 e.manifest_id, e.repository_url, e.name, e.summary, e.description,
                 e.category, e.tags_json, e.version, e.manifest_json, e.install_count,
                 (SELECT COUNT(*) FROM marketplace_extension_reports r
                   WHERE r.extension_id = e.id AND r.resolved_at IS NULL) AS report_count,
                 e.created_at, e.updated_at, e.hidden_at
            FROM marketplace_extensions e
            JOIN accounts a ON a.id = e.owner_account_id`;
}

function extensionDTO(row: ExtensionRow, context: MarketplaceContext): Record<string, unknown> {
  const manifest = parseStoredObject(row.manifest_json);
  const tags = parseStoredStringArray(row.tags_json);
  if (manifest === null || tags === null) throw new Error("Invalid marketplace JSON in D1.");
  const isOwner = row.owner_account_id === context.credential.accountId;
  return {
    id: row.id,
    repositoryUrl: row.repository_url,
    name: row.name,
    summary: row.summary,
    ...(row.description === null ? {} : { description: row.description }),
    ...(row.category === null ? {} : { category: row.category }),
    tags,
    version: row.version,
    manifest,
    owner: {
      id: row.owner_account_id,
      ...(row.owner_display_name === null ? {} : { displayName: row.owner_display_name }),
    },
    installCount: row.install_count,
    ...(context.isAdmin ? { reportCount: row.report_count } : {}),
    isOwner,
    canModerate: context.isAdmin,
    createdAt: isoDate(row.created_at),
    updatedAt: isoDate(row.updated_at),
    ...(row.hidden_at !== null && (isOwner || context.isAdmin) ? { isHidden: true } : {}),
  };
}

function canRead(row: ExtensionRow | null, context: MarketplaceContext): row is ExtensionRow {
  return row !== null && (
    row.hidden_at === null ||
    row.owner_account_id === context.credential.accountId ||
    context.isAdmin
  );
}

function adminAccountIDs(env: MarketplaceEnv): Set<string> {
  const raw = env.MARKETPLACE_ADMIN_ACCOUNT_IDS ?? "";
  if (raw.length > 4_096) return new Set();
  return new Set(raw.split(",").map((value) => value.trim()).filter(Boolean));
}

function auditInsert(
  db: D1Database,
  context: MarketplaceContext,
  action: string,
  targetType: string,
  targetId: string,
  occurredAt: number,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO audit_events
      (account_id, actor_type, actor_id, action, target_type, target_id, occurred_at)
     VALUES (?, 'desktop', ?, ?, ?, ?, ?)`,
  ).bind(
    context.credential.accountId,
    context.credential.subjectId,
    action,
    targetType,
    targetId,
    occurredAt,
  );
}

/** Must immediately follow its guarded mutation in the same D1 batch. */
function conditionalAuditInsert(
  db: D1Database,
  context: MarketplaceContext,
  action: string,
  targetType: string,
  targetId: string,
  occurredAt: number,
): D1PreparedStatement {
  return db.prepare(
    `INSERT INTO audit_events
      (account_id, actor_type, actor_id, action, target_type, target_id, occurred_at)
     SELECT ?, 'desktop', ?, ?, ?, ?, ?
      WHERE changes() = 1`,
  ).bind(
    context.credential.accountId,
    context.credential.subjectId,
    action,
    targetType,
    targetId,
    occurredAt,
  );
}

async function parseJSONBody(request: Request): Promise<JSONBody | Response> {
  const length = Number(request.headers.get("Content-Length") ?? "0");
  if (Number.isFinite(length) && length > MAX_BODY_BYTES) {
    return apiError(413, "request_too_large", "Request body is too large.");
  }
  const text = await request.text();
  if (new TextEncoder().encode(text).byteLength > MAX_BODY_BYTES) {
    return apiError(413, "request_too_large", "Request body is too large.");
  }
  try {
    const value: unknown = JSON.parse(text);
    if (!isRecord(value)) {
      return apiError(400, "invalid_json", "Request body must be a JSON object.");
    }
    if (containsLoneUTF16Surrogate(value)) {
      return apiError(
        400,
        "invalid_json",
        "Request body strings and object keys must contain valid Unicode.",
      );
    }
    return value;
  } catch {
    return apiError(400, "invalid_json", "Request body must be a JSON object.");
  }
}

function containsLoneUTF16Surrogate(value: unknown): boolean {
  if (typeof value === "string") return hasLoneUTF16Surrogate(value);
  if (Array.isArray(value)) return value.some(containsLoneUTF16Surrogate);
  if (!isRecord(value)) return false;
  return Object.entries(value).some(
    ([key, nestedValue]) =>
      hasLoneUTF16Surrogate(key) || containsLoneUTF16Surrogate(nestedValue),
  );
}

function hasLoneUTF16Surrogate(value: string): boolean {
  for (let index = 0; index < value.length; index += 1) {
    const codeUnit = value.charCodeAt(index);
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      if (index + 1 >= value.length) return true;
      const nextCodeUnit = value.charCodeAt(index + 1);
      if (nextCodeUnit < 0xdc00 || nextCodeUnit > 0xdfff) return true;
      index += 1;
    } else if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
      return true;
    }
  }
  return false;
}

function requiredString(value: unknown, field: string, maximumLength: number): string | Response {
  if (typeof value !== "string") {
    return apiError(400, "invalid_request", `${field} is required.`);
  }
  const trimmed = value.trim();
  return trimmed.length > 0 && trimmed.length <= maximumLength
    ? trimmed
    : apiError(400, "invalid_request", `${field} must be between 1 and ${maximumLength} characters.`);
}

function optionalString(
  body: JSONBody,
  field: string,
  maximumLength: number,
): string | null | Response {
  const value = body[field];
  if (value === undefined || value === null) return null;
  if (typeof value !== "string") {
    return apiError(400, "invalid_request", `${field} must be a string or null.`);
  }
  const trimmed = value.trim();
  if (trimmed.length === 0) return null;
  return trimmed.length <= maximumLength
    ? trimmed
    : apiError(400, "invalid_request", `${field} must not exceed ${maximumLength} characters.`);
}

function firstResponse(values: unknown[]): Response | null {
  return values.find((value): value is Response => value instanceof Response) ?? null;
}

function unknownKeys(body: JSONBody, allowed: string[]): string[] {
  const allowedSet = new Set(allowed);
  return Object.keys(body).filter((key) => !allowedSet.has(key)).sort();
}

function unknownFields(fields: string[]): Response {
  return apiError(400, "unknown_fields", `Unknown request fields: ${fields.join(", ")}.`);
}

function hasOwn(object: JSONBody, key: string): boolean {
  return Object.prototype.hasOwnProperty.call(object, key);
}

function isRecord(value: unknown): value is JSONBody {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseStoredObject(raw: string): JSONBody | null {
  try {
    const value: unknown = JSON.parse(raw);
    return isRecord(value) ? value : null;
  } catch {
    return null;
  }
}

function parseStoredStringArray(raw: string): string[] | null {
  try {
    const value: unknown = JSON.parse(raw);
    return Array.isArray(value) && value.every((item) => typeof item === "string")
      ? value
      : null;
  } catch {
    return null;
  }
}

function escapeLike(value: string): string {
  return value.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_");
}

function encodeCursor(cursor: Cursor): string {
  const bytes = new TextEncoder().encode(JSON.stringify(cursor));
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

function decodeCursor(raw: string): Cursor | null {
  if (raw.length === 0 || raw.length > 256 || !/^[A-Za-z0-9_-]+$/.test(raw)) return null;
  try {
    const padded = raw.replaceAll("-", "+").replaceAll("_", "/").padEnd(Math.ceil(raw.length / 4) * 4, "=");
    const binary = atob(padded);
    const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0));
    const value: unknown = JSON.parse(new TextDecoder().decode(bytes));
    if (
      !isRecord(value) ||
      typeof value.updatedAt !== "number" ||
      !Number.isSafeInteger(value.updatedAt) ||
      value.updatedAt < 0 ||
      typeof value.id !== "string" ||
      !EXTENSION_ID_PATTERN.test(value.id)
    ) {
      return null;
    }
    return { updatedAt: value.updatedAt, id: value.id };
  } catch {
    return null;
  }
}

function isLocalHostname(hostname: string): boolean {
  const normalized = hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (
    normalized === "localhost" ||
    normalized.endsWith(".localhost") ||
    normalized.endsWith(".local") ||
    normalized === "::1"
  ) return true;
  const ipv4 = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(normalized);
  if (ipv4) {
    const octets = ipv4.slice(1).map(Number);
    if (octets.some((octet) => octet > 255)) return true;
    const first = octets[0] ?? 0;
    const second = octets[1] ?? 0;
    return first === 0 || first === 10 || first === 127 ||
      (first === 169 && second === 254) ||
      (first === 172 && second >= 16 && second <= 31) ||
      (first === 192 && second === 168);
  }
  return normalized.includes(":") && (
    normalized === "::" ||
    normalized.startsWith("fc") ||
    normalized.startsWith("fd") ||
    normalized.startsWith("fe80:") ||
    normalized.startsWith("::ffff:")
  );
}

function conflictResponse(conflict: "repository" | "manifest"): Response {
  return conflict === "repository"
    ? apiError(409, "repository_exists", "This repository is already published.")
    : apiError(409, "manifest_id_exists", "An extension with this manifest id is already published.");
}

function authenticationError<T>(failure: Exclude<AuthenticationResult<T>, { ok: true }>): Response {
  return apiError(failure.status, failure.code, failure.message);
}

function methodNotAllowed(allow: string): Response {
  const response = apiError(405, "method_not_allowed", "Method not allowed.");
  response.headers.set("Allow", allow);
  return response;
}

function apiResponse(body: Record<string, unknown>, status = 200): Response {
  return Response.json(body, {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

function apiError(status: number, code: string, message: string): Response {
  return apiResponse({ error: { code, message } }, status);
}

function isUniqueConstraintError(error: unknown): boolean {
  return error instanceof Error && error.message.toLowerCase().includes("unique constraint");
}

function isoDate(milliseconds: number): string {
  return new Date(milliseconds).toISOString();
}

function changes(result: D1Result<unknown> | undefined): number {
  return result?.meta.changes ?? 0;
}
