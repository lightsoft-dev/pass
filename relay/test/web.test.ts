import { SELF } from "cloudflare:test";
import { describe, expect, it } from "vitest";

// @ts-expect-error The browser asset is intentionally plain JavaScript and has no build step.
import { PassAPIError, parseAPIResponse } from "../public/api-error.js";

describe("browser API response parsing", () => {
  it("preserves the explicit Apple manual-revocation fallback signal", () => {
    let caught: unknown;
    try {
      parseAPIResponse(
        { ok: false, status: 503 },
        {
          error: {
            code: "apple_service_unavailable",
            message: "Apple token revocation is temporarily unavailable.",
            retryable: true,
            action: "retry",
            manualRevocationAvailable: true,
          },
        },
      );
    } catch (error) {
      caught = error;
    }

    expect(caught).toBeInstanceOf(PassAPIError);
    expect(caught).toMatchObject({
      status: 503,
      code: "apple_service_unavailable",
      message: "Apple token revocation is temporarily unavailable.",
      retryable: true,
      action: "retry",
      manualRevocationAvailable: true,
    });
  });

  it("does not invent manual fallback availability for unrelated errors", () => {
    expect(() => parseAPIResponse(
      { ok: false, status: 503 },
      { error: { code: "apple_operation_in_progress", message: "Retry shortly." } },
    )).toThrow(expect.objectContaining({
      code: "apple_operation_in_progress",
      manualRevocationAvailable: false,
    }));
  });

  it("ships the guarded manual-deletion flow with redirect blocking and Apple guidance", async () => {
    const response = await SELF.fetch("https://relay.test/app.js");
    expect(response.status).toBe(200);
    const source = await response.text();
    expect(source).toContain('redirect: "error"');
    expect(source).toContain('"X-Pass-Apple-Revocation-Fallback": "manual"');
    expect(source).toContain("Apple Settings > [name] > Sign-In & Security > Sign in with Apple > Pass");
  });
});
