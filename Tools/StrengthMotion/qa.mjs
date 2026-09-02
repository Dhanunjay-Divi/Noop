import assert from "node:assert/strict";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { chromium } from "playwright";

const root = fileURLToPath(new URL(".", import.meta.url));
const manifest = JSON.parse(await readFile(join(root, "manifest.json"), "utf8"));
const source = await readFile(join(root, "viewer.ts"), "utf8");
const exercises = manifest.exercises.map(({ id }) => id);
const mappingBlock = source.match(/const mediaIds:[\s\S]*?= \{([\s\S]*?)\n\};/)?.[1] ?? "";
const mappings = new Map(
  [...mappingBlock.matchAll(/^\s{2}([a-z0-9_]+): "([A-Za-z0-9]+)",$/gm)]
    .map((match) => [match[1], match[2]]),
);

assert.equal(mappings.size, exercises.length, "media mapping count must match manifest");
for (const id of exercises) assert(mappings.has(id), `missing media mapping for ${id}`);

const failures = [];
await Promise.all(exercises.map(async (id) => {
  const response = await fetch(`https://static.exercisedb.dev/media/${mappings.get(id)}.gif`);
  if (!response.ok || !response.headers.get("content-type")?.includes("image/gif")) {
    failures.push(`${id}: media returned ${response.status}`);
  }
}));

const server = createServer(async (request, response) => {
  try {
    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    const relative = url.pathname === "/" ? "index.html" : url.pathname.slice(1);
    const file = relative === "viewer.js" ? join(root, "dist", "viewer.js") : join(root, relative);
    response.setHeader("Content-Type", mimeType(file));
    response.end(await readFile(file));
  } catch {
    response.statusCode = 404;
    response.end("Not found");
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const address = server.address();
assert(address && typeof address === "object");

const browser = await chromium.launch({ channel: "chrome", headless: true });
const page = await browser.newPage({ viewport: { width: 390, height: 844 } });
for (const id of exercises) {
  try {
    await page.goto(`http://127.0.0.1:${address.port}/?exercise=${id}`);
    await page.locator("body[data-ready='true']").waitFor();
    assert((await page.locator("#motion").evaluate((image) => image.naturalWidth)) > 0);
    assert((await page.locator("#exercise-title").textContent())?.trim());
  } catch (error) {
    failures.push(`${id}: ${error instanceof Error ? error.message : String(error)}`);
  }
}
await page.locator("#info").click();
assert.equal(await page.locator("#instructions").getAttribute("hidden"), null);
for (const id of ["instruction-setup", "instruction-movement", "instruction-safety"]) {
  assert((await page.locator(`#${id}`).textContent())?.trim().length >= 24);
}
await page.screenshot({ path: "/tmp/noop-strength-motion-exercisedb.png", fullPage: true });
await browser.close();
await new Promise((resolve, reject) => server.close((error) => error ? reject(error) : resolve()));

if (failures.length) {
  console.error(failures.join("\n"));
  process.exitCode = 1;
} else {
  console.log(`QA passed: ${exercises.length} mapped, reachable, rendered exercise guides`);
}

function mimeType(file) {
  switch (extname(file)) {
    case ".html": return "text/html; charset=utf-8";
    case ".css": return "text/css; charset=utf-8";
    case ".js": return "text/javascript; charset=utf-8";
    default: return "application/octet-stream";
  }
}
