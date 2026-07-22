import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const [xtermSource, xtermCSS] = await Promise.all([
  readFile(resolve(root, "node_modules/@xterm/xterm/lib/xterm.js"), "utf8"),
  readFile(resolve(root, "node_modules/@xterm/xterm/css/xterm.css"), "utf8"),
]);

const safeScript = xtermSource.replace(/<\/script/gi, "<\\/script");
const safeCSS = xtermCSS.replace(/<\/style/gi, "<\\/style");
const html = `<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; font-src data:">
  <style>${safeCSS}
    :root { color-scheme: dark; }
    html, body { width: 100%; height: 100%; margin: 0; background: #090b0f; overflow: hidden; }
    body { overscroll-behavior: none; touch-action: manipulation; }
    #terminal-scroll { width: 100%; height: 100%; overflow: auto; overscroll-behavior: contain; -webkit-overflow-scrolling: touch; }
    #terminal-stage { position: relative; min-width: 100%; min-height: 100%; }
    #terminal { box-sizing: border-box; position: absolute; top: 0; left: 0; min-width: 100%; min-height: 100%; padding: 8px 6px; transform-origin: top left; }
    .xterm { height: 100%; }
    .xterm .xterm-viewport { overscroll-behavior: contain; }
  </style>
</head>
<body>
  <div id="terminal-scroll"><div id="terminal-stage"><div id="terminal" role="application" aria-label="Remote tmux terminal"></div></div></div>
  <script>${safeScript}</script>
  <script>
    (() => {
      const terminal = new Terminal({
        allowProposedApi: false,
        convertEol: true,
        cursorBlink: true,
        cursorStyle: 'block',
        disableStdin: false,
        fontFamily: 'Menlo, ui-monospace, SFMono-Regular, monospace',
        fontSize: 10,
        fontWeight: '400',
        letterSpacing: 0,
        lineHeight: 1.1,
        scrollback: 0,
        theme: {
          background: '#090b0f', foreground: '#d7dce2', cursor: '#6ee7b7', cursorAccent: '#090b0f',
          selectionBackground: '#31594c99', black: '#111318', red: '#ef6b73', green: '#72d39a',
          yellow: '#e8c76a', blue: '#75a7ef', magenta: '#c59bf4', cyan: '#68c7d4', white: '#d7dce2',
          brightBlack: '#646b75', brightRed: '#ff858c', brightGreen: '#8ce7ad', brightYellow: '#f4d982',
          brightBlue: '#91baff', brightMagenta: '#d7b2ff', brightCyan: '#83dae4', brightWhite: '#ffffff'
        }
      });
      const scrollElement = document.getElementById('terminal-scroll');
      const stageElement = document.getElementById('terminal-stage');
      const terminalElement = document.getElementById('terminal');
      terminal.open(terminalElement);

      const emit = (message) => {
        window.ReactNativeWebView?.postMessage(JSON.stringify(message));
      };
      terminal.onData((data) => emit({ type: 'input', data }));

      let pendingSnapshot = null;
      let writing = false;
      let composing = false;
      let viewportMode = 'readable';
      let rendererScale = 1;
      let layoutFrame = null;
      const layoutTerminal = () => {
        if (layoutFrame !== null) cancelAnimationFrame(layoutFrame);
        layoutFrame = requestAnimationFrame(() => {
          layoutFrame = null;
          const screen = terminal.element?.querySelector('.xterm-screen');
          if (!screen) return;
          const screenBounds = screen.getBoundingClientRect();
          const logicalWidth = Math.max(1, screenBounds.width / rendererScale + 12);
          const logicalHeight = Math.max(1, screenBounds.height / rendererScale + 16);
          const availableWidth = Math.max(1, scrollElement.clientWidth);
          const fitScale = Math.min(1, availableWidth / logicalWidth);
          rendererScale = viewportMode === 'fit'
            ? fitScale
            : viewportMode === 'readable'
              ? Math.max(0.8, fitScale)
              : 1;
          terminalElement.style.width = logicalWidth + 'px';
          terminalElement.style.height = logicalHeight + 'px';
          terminalElement.style.transform = 'scale(' + rendererScale + ')';
          stageElement.style.width = viewportMode === 'fit'
            ? '100%'
            : Math.max(availableWidth, logicalWidth * rendererScale) + 'px';
          stageElement.style.height = Math.max(scrollElement.clientHeight, logicalHeight * rendererScale) + 'px';
        });
      };
      const renderNext = () => {
        if (writing || composing || pendingSnapshot === null) return;
        const snapshot = pendingSnapshot;
        pendingSnapshot = null;
        writing = true;
        const columns = Math.max(1, Math.min(1000, snapshot.columns));
        const rows = Math.max(1, Math.min(1000, snapshot.rows));
        if (terminal.cols !== columns || terminal.rows !== rows) terminal.resize(columns, rows);
        terminal.reset();
        const cursor = '\\x1b[' + (snapshot.cursorY + 1) + ';' + (snapshot.cursorX + 1) + 'H';
        const frame = '\\x1b[?25l\\x1b[H\\x1b[2J' + (snapshot.content || '') + cursor + '\\x1b[?25h';
        terminal.write(frame, () => {
          writing = false;
          layoutTerminal();
          if (pendingSnapshot !== null) renderNext();
        });
      };

      const receive = (raw) => {
        try {
          const message = typeof raw === 'string' ? JSON.parse(raw) : raw;
          if (message.type === 'snapshot' && typeof message.content === 'string') {
            pendingSnapshot = message;
            renderNext();
          } else if (message.type === 'input' && typeof message.data === 'string') {
            terminal.input(message.data, true);
          } else if (message.type === 'fontSize' && Number.isFinite(message.value)) {
            terminal.options.fontSize = Math.max(7, Math.min(18, message.value));
            terminal.refresh(0, terminal.rows - 1);
            layoutTerminal();
          } else if (message.type === 'viewportMode' && (message.value === 'readable' || message.value === 'fit' || message.value === 'native')) {
            viewportMode = message.value;
            layoutTerminal();
          } else if (message.type === 'focus') {
            terminal.focus();
          }
        } catch (error) {
          emit({ type: 'error', message: String(error) });
        }
      };

      window.addEventListener('message', (event) => receive(event.data));
      document.addEventListener('message', (event) => receive(event.data));
      terminal.textarea?.addEventListener('compositionstart', () => {
        composing = true;
      });
      terminal.textarea?.addEventListener('compositionend', () => {
        composing = false;
        pendingSnapshot = null;
      });
      new ResizeObserver(layoutTerminal).observe(scrollElement);
      terminalElement.addEventListener('click', () => terminal.focus());
      window.passTerminal = { receive };
      layoutTerminal();
      emit({ type: 'ready' });
    })();
  </script>
</body>
</html>`;

const target = resolve(root, "src/terminal/terminalDocument.generated.ts");
await mkdir(dirname(target), { recursive: true });
await writeFile(
  target,
  `// Generated by scripts/build-terminal-document.mjs. Do not edit.\nexport const terminalDocument = ${JSON.stringify(html)};\n`,
);
console.log("Generated xterm WebView document");
