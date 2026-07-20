import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const target = fileURLToPath(
  new URL(
    "../node_modules/expo-modules-jsi/apple/Sources/ExpoModulesJSI/Coding/JavaScriptCodable+Date.swift",
    import.meta.url,
  ),
);
const ambiguousCall =
  "guard milliseconds.isFinite, abs(milliseconds) <= maxJavaScriptDateMilliseconds else {";
const qualifiedCall =
  "guard milliseconds.isFinite, Swift.abs(milliseconds) <= maxJavaScriptDateMilliseconds else {";

const source = await readFile(target, "utf8");

if (source.includes(qualifiedCall)) {
  console.log("expo-modules-jsi Xcode compatibility patch already applied");
} else if (source.includes(ambiguousCall)) {
  await writeFile(target, source.replace(ambiguousCall, qualifiedCall));
  console.log("Applied expo-modules-jsi Xcode compatibility patch");
} else {
  throw new Error(
    "expo-modules-jsi changed; verify whether the Xcode compatibility patch is still required",
  );
}
