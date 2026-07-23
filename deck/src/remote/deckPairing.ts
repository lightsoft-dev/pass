import { createDecipheriv, generateKeyPairSync, privateDecrypt, constants } from "node:crypto";
import QRCode from "qrcode";
import type { PairingProfile } from "../shared/types.ts";

type PairingCreated = {
  pairing: {
    v: 3; relayUrl: string; pairingId: string; approvalSecret: string;
    pollSecret: string; deviceName: string; expiresAt: string;
  };
};
type CredentialEnvelope = { wrappedKey: string; iv: string; ciphertext: string };

function bytes(value: string): Buffer {
  return Buffer.from(value.replaceAll("-", "+").replaceAll("_", "/"), "base64");
}

export function normalizeRelayBase(raw: string): string {
  const url = new URL(raw.trim());
  if (url.protocol !== "https:" && !(process.env.NODE_ENV !== "production" && url.protocol === "http:")) {
    throw new Error("Relay URL은 HTTPS여야 합니다.");
  }
  if (url.username || url.password || !url.hostname) throw new Error("Relay URL이 올바르지 않습니다.");
  url.pathname = url.pathname.replace(/\/connect\/?$/, "").replace(/\/+$/, "");
  url.search = ""; url.hash = "";
  return url.toString().replace(/\/$/, "");
}

export class DeckPairingClient {
  private stopped = false;

  stop(): void { this.stopped = true; }

  async start(
    relayInput: string,
    onChallenge: (value: { qrDataURL: string; deviceName: string; expiresAt: string }) => void,
  ): Promise<PairingProfile> {
    this.stopped = false;
    const relayUrl = normalizeRelayBase(relayInput);
    const { publicKey, privateKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
    const deviceName = "Steam Deck";
    const response = await fetch(`${relayUrl}/v2/deck-pairings`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ deviceName, publicKey: publicKey.export({ format: "jwk" }) }),
    });
    const created = await response.json() as PairingCreated & { error?: { message?: string } };
    if (!response.ok) throw new Error(created.error?.message ?? `Pairing failed with HTTP ${response.status}.`);
    const { pollSecret, ...approvalPayload } = created.pairing;
    const qrDataURL = await QRCode.toDataURL(JSON.stringify(approvalPayload), {
      errorCorrectionLevel: "M", margin: 1, width: 440,
      color: { dark: "#0a0d0c", light: "#e8ede6" },
    });
    onChallenge({ qrDataURL, deviceName, expiresAt: created.pairing.expiresAt });

    while (!this.stopped && Date.now() < Date.parse(created.pairing.expiresAt)) {
      await new Promise((resolve) => setTimeout(resolve, 1500));
      const poll = await fetch(`${relayUrl}/v2/deck-pairings/${encodeURIComponent(created.pairing.pairingId)}/poll`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ pollSecret }),
      });
      const result = await poll.json() as { status?: string; envelope?: CredentialEnvelope; error?: { message?: string } };
      if (poll.status === 202) continue;
      if (!poll.ok || result.status !== "approved" || !result.envelope) {
        throw new Error(result.error?.message ?? "Deck pairing could not be completed.");
      }
      const key = privateDecrypt(
        { key: privateKey, padding: constants.RSA_PKCS1_OAEP_PADDING, oaepHash: "sha256" },
        bytes(result.envelope.wrappedKey),
      );
      const encrypted = bytes(result.envelope.ciphertext);
      const decipher = createDecipheriv("aes-256-gcm", key, bytes(result.envelope.iv));
      decipher.setAuthTag(encrypted.subarray(encrypted.length - 16));
      const plaintext = Buffer.concat([decipher.update(encrypted.subarray(0, -16)), decipher.final()]);
      const handoff = JSON.parse(plaintext.toString("utf8")) as {
        relayUrl: string; desktopId: string; desktopName: string; deviceId: string;
        credentials: { accessToken: string; accessExpiresAt: string; refreshToken: string; refreshExpiresAt: string };
      };
      return {
        relayUrl: handoff.relayUrl,
        desktopId: handoff.desktopId,
        desktopName: handoff.desktopName,
        deviceId: handoff.deviceId,
        credential: handoff.credentials.accessToken,
        credentialExpiresAt: handoff.credentials.accessExpiresAt,
        refreshCredential: handoff.credentials.refreshToken,
        refreshExpiresAt: handoff.credentials.refreshExpiresAt,
      };
    }
    throw new Error("Deck pairing code expired. Generate a new one.");
  }
}
