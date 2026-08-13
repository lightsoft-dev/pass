import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const EXPECTED_ICON_SHA256 = "b638264622926ac4f6c91e2acd36b7dd1e4e4d763f78b2d48758d5488ecd44c5";
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const projectDirectory = resolve(scriptDirectory, "..");
const config = JSON.parse(await readFile(resolve(projectDirectory, "app.json"), "utf8"));
const expo = config.expo;
const configuredPaths = [expo.icon, expo.ios?.icon, expo.android?.icon];

if (configuredPaths.some((path) => path !== "./assets/icon.png")) {
  throw new Error(
    `App icon paths must all reference ./assets/icon.png; received ${configuredPaths.join(", ")}`,
  );
}

const icon = await readFile(resolve(projectDirectory, "assets/icon.png"));
const pngSignature = "89504e470d0a1a0a";
if (icon.subarray(0, 8).toString("hex") !== pngSignature) {
  throw new Error("assets/icon.png is not a PNG file.");
}

const width = icon.readUInt32BE(16);
const height = icon.readUInt32BE(20);
const bitDepth = icon[24];
const colorType = icon[25];
if (width !== 1024 || height !== 1024 || bitDepth !== 8 || colorType !== 2) {
  throw new Error(
    `assets/icon.png must be a 1024x1024, 8-bit RGB PNG without alpha; received ${width}x${height}, bit depth ${bitDepth}, color type ${colorType}.`,
  );
}

const actualHash = createHash("sha256").update(icon).digest("hex");
if (actualHash !== EXPECTED_ICON_SHA256) {
  throw new Error(
    `assets/icon.png does not match the approved desktop Pass artwork. Expected ${EXPECTED_ICON_SHA256}, received ${actualHash}.`,
  );
}

console.log(`Verified Pass mobile app icon (${width}x${height}, sha256:${actualHash}).`);
