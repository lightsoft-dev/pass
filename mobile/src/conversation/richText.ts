export type TableAlignment = "left" | "center" | "right";

export type RichSection =
  | { kind: "paragraph"; text: string }
  | { kind: "heading"; text: string }
  | { kind: "bullet"; text: string }
  | { kind: "number"; marker: string; text: string }
  | { kind: "code"; language?: string; text: string }
  | {
      kind: "table";
      headers: string[];
      alignments: TableAlignment[];
      rows: string[][];
    };

function splitTableRow(value: string): string[] | null {
  let line = value.trim();
  if (!line.includes("|")) return null;
  if (line.startsWith("|")) line = line.slice(1);
  if (line.endsWith("|") && !line.endsWith("\\|")) line = line.slice(0, -1);

  const cells: string[] = [];
  let cell = "";
  let escaped = false;
  let inCode = false;
  let sawSeparator = false;

  for (const character of line) {
    if (escaped) {
      if (character !== "|" && character !== "\\" && character !== "`") cell += "\\";
      cell += character;
      escaped = false;
    } else if (character === "\\") {
      escaped = true;
    } else if (character === "`") {
      inCode = !inCode;
      cell += character;
    } else if (character === "|" && !inCode) {
      cells.push(cell.trim());
      cell = "";
      sawSeparator = true;
    } else {
      cell += character;
    }
  }
  if (escaped) cell += "\\";
  cells.push(cell.trim());
  return sawSeparator && cells.length >= 2 ? cells : null;
}

function tableAlignment(value: string): TableAlignment | null {
  const marker = value.replace(/\s/g, "");
  if (!/^:?-{3,}:?$/.test(marker)) return null;
  if (marker.startsWith(":") && marker.endsWith(":")) return "center";
  if (marker.endsWith(":")) return "right";
  return "left";
}

function normalizeRow(row: string[], columnCount: number): string[] {
  return Array.from({ length: columnCount }, (_, index) => row[index] ?? "");
}

export function parseRichSections(value: string): RichSection[] {
  const sections: RichSection[] = [];
  const lines = value.replace(/\r/g, "").split("\n");
  let paragraph: string[] = [];
  let code: string[] | null = null;
  let language: string | undefined;

  const flushParagraph = () => {
    const text = paragraph.join(" ").trim();
    if (text) sections.push({ kind: "paragraph", text });
    paragraph = [];
  };

  for (let index = 0; index < lines.length; index += 1) {
    const raw = lines[index] ?? "";
    const line = raw.trimEnd();
    const fence = line.trim().match(/^```([^`]*)$/);
    if (fence) {
      if (code) {
        sections.push({ kind: "code", text: code.join("\n"), ...(language ? { language } : {}) });
        code = null;
        language = undefined;
      } else {
        flushParagraph();
        code = [];
        language = fence[1]?.trim() || undefined;
      }
      continue;
    }
    if (code) {
      code.push(raw);
      continue;
    }
    if (!line.trim()) {
      flushParagraph();
      continue;
    }

    const headers = splitTableRow(line);
    const separator = splitTableRow(lines[index + 1] ?? "");
    const alignments = separator?.map(tableAlignment) ?? [];
    if (
      headers &&
      separator &&
      separator.length === headers.length &&
      alignments.every((alignment) => alignment !== null)
    ) {
      flushParagraph();
      const rows: string[][] = [];
      index += 2;
      while (index < lines.length) {
        if (!(lines[index] ?? "").trim()) {
          index -= 1;
          break;
        }
        const row = splitTableRow(lines[index] ?? "");
        if (!row) {
          index -= 1;
          break;
        }
        rows.push(normalizeRow(row, headers.length));
        index += 1;
      }
      sections.push({
        kind: "table",
        headers,
        alignments: alignments as TableAlignment[],
        rows,
      });
      continue;
    }

    const heading = line.match(/^#{1,4}\s+(.+)$/);
    const bullet = line.match(/^[-*]\s+(.+)$/);
    const numbered = line.match(/^(\d+[.)])\s+(.+)$/);
    if (heading?.[1]) {
      flushParagraph();
      sections.push({ kind: "heading", text: heading[1] });
    } else if (bullet?.[1]) {
      flushParagraph();
      sections.push({ kind: "bullet", text: bullet[1] });
    } else if (numbered?.[1] && numbered[2]) {
      flushParagraph();
      sections.push({ kind: "number", marker: numbered[1], text: numbered[2] });
    } else {
      paragraph.push(line.trim());
    }
  }
  if (code) sections.push({ kind: "code", text: code.join("\n"), ...(language ? { language } : {}) });
  flushParagraph();
  return sections;
}
