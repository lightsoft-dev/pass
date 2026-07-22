import assert from "node:assert/strict";
import test from "node:test";

import { parseRichSections } from "./richText.ts";

test("parses a markdown table with column alignment", () => {
  const sections = parseRichSections(`Result:

| Name | Status | Duration |
| :--- | :---: | ---: |
| Build | Passed | 14s |
| Tests | Running | 2m |`);

  assert.deepEqual(sections, [
    { kind: "paragraph", text: "Result:" },
    {
      kind: "table",
      headers: ["Name", "Status", "Duration"],
      alignments: ["left", "center", "right"],
      rows: [
        ["Build", "Passed", "14s"],
        ["Tests", "Running", "2m"],
      ],
    },
  ]);
});

test("keeps escaped and inline-code pipes inside table cells", () => {
  const sections = parseRichSections(`Key | Value
--- | ---
literal | a\\|b
command | \`foo | bar\``);

  assert.equal(sections[0]?.kind, "table");
  if (sections[0]?.kind !== "table") return;
  assert.deepEqual(sections[0].rows, [
    ["literal", "a|b"],
    ["command", "`foo | bar`"],
  ]);
});

test("does not parse table syntax inside a code fence", () => {
  assert.deepEqual(parseRichSections("```md\n| A | B |\n| --- | --- |\n```"), [
    { kind: "code", language: "md", text: "| A | B |\n| --- | --- |" },
  ]);
});
