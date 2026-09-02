export type AccountDeletionResult = {
  deleted: true;
  appleRevocation?: "manual_required";
};

export type AccountDeletionOptions = {
  appleRevocationFallback?: "manual";
  fetchImpl?: typeof fetch;
};

export class AccountDeletionError extends Error {
  readonly code: string | null;
  readonly status: number;
  readonly manualRevocationAvailable: boolean;

  constructor(
    message: string,
    options: {
      code: string | null;
      status: number;
      manualRevocationAvailable: boolean;
    },
  ) {
    super(message);
    this.name = "AccountDeletionError";
    this.code = options.code;
    this.status = options.status;
    this.manualRevocationAvailable = options.manualRevocationAvailable;
  }
}

export async function deleteAccount(
  configuredRelayUrl: string,
  userAccessToken: string,
  options: AccountDeletionOptions = {},
): Promise<AccountDeletionResult> {
  const headers: Record<string, string> = {
    Authorization: `Bearer ${userAccessToken}`,
  };
  if (options.appleRevocationFallback === "manual") {
    headers["X-Pass-Apple-Revocation-Fallback"] = "manual";
  }
  const response = await (options.fetchImpl ?? fetch)(
    `${configuredRelayUrl.replace(/\/+$/, "")}/v2/account`,
    {
      method: "DELETE",
      redirect: "error",
      headers,
    },
  );
  const payload: unknown = await response.json().catch(() => null);
  if (!response.ok) {
    const apiError = parseApiError(payload);
    throw new AccountDeletionError(
      apiError?.message ?? `Account deletion failed with HTTP ${response.status}.`,
      {
        code: apiError?.code ?? null,
        status: response.status,
        manualRevocationAvailable: apiError?.manualRevocationAvailable === true,
      },
    );
  }
  if (
    !isRecord(payload)
    || payload.deleted !== true
    || (payload.appleRevocation !== undefined
      && payload.appleRevocation !== "manual_required")
  ) {
    throw new Error("Account deletion server returned an invalid response.");
  }
  return {
    deleted: true,
    ...(payload.appleRevocation === "manual_required"
      ? { appleRevocation: "manual_required" as const }
      : {}),
  };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseApiError(payload: unknown): {
  code: string | null;
  message: string | null;
  manualRevocationAvailable: boolean;
} | null {
  if (!isRecord(payload) || !isRecord(payload.error)) return null;
  const message = payload.error.message;
  const code = payload.error.code;
  return {
    code: typeof code === "string" && code.length > 0 && code.length <= 100
      ? code
      : null,
    message: typeof message === "string" && message.length > 0 && message.length <= 500
      ? message
      : null,
    manualRevocationAvailable:
      payload.error.manualRevocationAvailable === true,
  };
}
