// The page a sign-in's browser shows when it returns to the app, in place of pi-ai's (`utils/oauth-page.js`, which
// shows pi's logo): a green checkmark, or a red cross, in a circle, with the message under it. Same exports, so pi-ai's
// callback servers use it unchanged; build.mjs routes their import here.

function escapeHtml(value: string): string {
	return value
		.replaceAll("&", "&amp;")
		.replaceAll("<", "&lt;")
		.replaceAll(">", "&gt;")
		.replaceAll('"', "&quot;")
		.replaceAll("'", "&#39;");
}

const check = `<svg viewBox="0 0 64 64" aria-hidden="true"><circle cx="32" cy="32" r="32" fill="#34C759"/><path d="M19 33.5l8.5 8.5L45 23.5" fill="none" stroke="#fff" stroke-width="5.5" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
const cross = `<svg viewBox="0 0 64 64" aria-hidden="true"><circle cx="32" cy="32" r="32" fill="#FF3B30"/><path d="M22 22l20 20M42 22L22 42" fill="none" stroke="#fff" stroke-width="5.5" stroke-linecap="round"/></svg>`;

function renderPage(options: { title: string; icon: string; message: string; details?: string }): string {
	const details = options.details ? `<p class="details">${escapeHtml(options.details)}</p>` : "";
	return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(options.title)}</title>
  <style>
    :root { color-scheme: light dark; }
    body {
      margin: 0;
      min-height: 100vh;
      display: flex;
      align-items: center;
      justify-content: center;
      font: 17px -apple-system, system-ui, sans-serif;
      background: Canvas;
      color: CanvasText;
      text-align: center;
    }
    main { padding: 32px; max-width: 420px; }
    svg { width: 72px; height: 72px; }
    h1 { margin: 20px 0 8px; font-size: 22px; font-weight: 600; }
    p { margin: 0; line-height: 1.4; color: #8E8E93; }
    .details { margin-top: 12px; font: 13px ui-monospace, monospace; white-space: pre-wrap; word-break: break-word; }
  </style>
</head>
<body>
  <main>
    ${options.icon}
    <h1>${escapeHtml(options.title)}</h1>
    <p>${escapeHtml(options.message)}</p>
    ${details}
  </main>
</body>
</html>`;
}

export function oauthSuccessHtml(message: string): string {
	return renderPage({ title: "Signed In", icon: check, message });
}

export function oauthErrorHtml(message: string, details?: string): string {
	return renderPage({ title: "Couldn't Sign In", icon: cross, message, details });
}
