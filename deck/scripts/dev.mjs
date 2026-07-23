import { spawn } from "node:child_process";
import "./build.mjs";

const child = spawn("electron", ["dist/main.cjs", "--dev"], {
  stdio: "inherit",
  shell: process.platform === "win32",
});
child.on("exit", (code) => process.exit(code ?? 0));
