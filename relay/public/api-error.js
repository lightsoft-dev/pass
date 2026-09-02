export class PassAPIError extends Error {
  constructor(status, payload) {
    const error = payload && typeof payload === "object" && !Array.isArray(payload)
      ? payload.error
      : null;
    const details = error && typeof error === "object" && !Array.isArray(error)
      ? error
      : null;
    const message = typeof details?.message === "string"
      ? details.message
      : typeof error === "string"
      ? error
      : "요청을 처리할 수 없습니다.";
    super(message);
    this.name = "PassAPIError";
    this.status = status;
    this.code = typeof details?.code === "string" ? details.code : null;
    this.retryable = details?.retryable === true;
    this.action = typeof details?.action === "string" ? details.action : null;
    this.manualRevocationAvailable = details?.manualRevocationAvailable === true;
  }
}

export function parseAPIResponse(response, body) {
  if (response.ok) return body;
  throw new PassAPIError(response.status, body);
}
