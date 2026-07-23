#!/usr/bin/env node
// CLI wrapper for rota-device-frame-sandbox.html.
// Loads the sandbox in headless Chrome, injects a screenshot + settings,
// clicks the page's own Export button, and saves the resulting PNG.
//
// Usage:
//   node frame.mjs <screenshot.png> [more.png ...] [flags]
//
// Flags (mirror the sandbox panel):
//   --mode <iphone|ipadp|ipadl>   device frame            (default iphone)
//   --rz <deg>                    rotate                  (default 0)
//   --tx <deg>                    3D tilt X               (default 0)
//   --ty <deg>                    3D tilt Y               (default 0)
//   --persp <px>                  perspective             (default 1600)
//   --margin <px>                 canvas margin           (default 60)
//   --escale <percent>            export scale, 25-200    (default 100)
//   --no-island                   hide Dynamic Island / camera dot
//   --settings <file.json>        load a "Copy settings JSON" preset
//                                 (explicit flags still override it)
//   --out <path>                  output file (single input only);
//                                 default: "../sandboxed pics/<stem>-framed.png"
//   --outdir <dir>                output directory for defaults

import { chromium } from 'playwright-core';
import { readFileSync, mkdirSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SANDBOX = path.resolve(__dirname, '..', 'rota-device-frame-sandbox.html');
const DEFAULT_OUTDIR = path.resolve(__dirname, '..', 'sandboxed pics');

function die(msg) {
  console.error('error: ' + msg);
  console.error('run with --help for usage');
  process.exit(1);
}

function usage() {
  const src = readFileSync(fileURLToPath(import.meta.url), 'utf8');
  console.log(src.split('\n').slice(1, 24).map(l => l.replace(/^\/\/ ?/, '')).join('\n'));
  process.exit(0);
}

// ---------- arg parsing ----------
const argv = process.argv.slice(2);
if (argv.length === 0 || argv.includes('--help') || argv.includes('-h')) usage();

const inputs = [];
const settings = {};           // partial overrides applied onto the page's S
let out = null, outdir = DEFAULT_OUTDIR, settingsFile = null;

const NUMERIC = { '--rz': 'rz', '--tx': 'tx', '--ty': 'ty', '--persp': 'persp', '--margin': 'margin' };

for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (NUMERIC[a]) {
    const v = parseFloat(argv[++i]);
    if (Number.isNaN(v)) die(a + ' needs a number');
    settings[NUMERIC[a]] = v;
  } else if (a === '--escale') {
    const v = parseFloat(argv[++i]);
    if (Number.isNaN(v) || v < 25 || v > 200) die('--escale needs a percent between 25 and 200');
    settings.escale = v / 100;
  } else if (a === '--mode' || a === '-m') {
    const v = argv[++i];
    if (!['iphone', 'ipadp', 'ipadl'].includes(v)) die('--mode must be iphone, ipadp, or ipadl');
    settings.mode = v;
  } else if (a === '--island') {
    settings.islandOn = true;
  } else if (a === '--no-island') {
    settings.islandOn = false;
  } else if (a === '--settings') {
    settingsFile = argv[++i];
  } else if (a === '--out' || a === '-o') {
    out = argv[++i];
  } else if (a === '--outdir') {
    outdir = path.resolve(argv[++i]);
  } else if (a.startsWith('-')) {
    die('unknown flag ' + a);
  } else {
    inputs.push(a);
  }
}

if (inputs.length === 0) die('no input image given');
if (out && inputs.length > 1) die('--out only works with a single input; use --outdir for batches');

// preset file first, explicit flags win
let finalSettings = {};
if (settingsFile) {
  try {
    finalSettings = JSON.parse(readFileSync(settingsFile, 'utf8'));
  } catch (e) {
    die('could not read settings JSON: ' + e.message);
  }
}
Object.assign(finalSettings, settings);
delete finalSettings.zoom; // preview-only, irrelevant to export

if (!existsSync(SANDBOX)) die('sandbox HTML not found at ' + SANDBOX);

const jobs = inputs.map(p => {
  const abs = path.resolve(p);
  if (!existsSync(abs)) die('input not found: ' + abs);
  const stem = path.basename(abs).replace(/\.[^.]+$/, '');
  const outPath = out ? path.resolve(out) : path.join(outdir, stem + '-framed.png');
  return { abs, outPath };
});

// ---------- render ----------
mkdirSync(outdir, { recursive: true });

const browser = await chromium.launch({ channel: 'chrome', headless: true });
try {
  const ctx = await browser.newContext({ acceptDownloads: true });
  const page = await ctx.newPage();
  await page.goto(pathToFileURL(SANDBOX).href);

  for (const job of jobs) {
    const dataUrl = 'data:image/png;base64,' + readFileSync(job.abs).toString('base64');

    await page.evaluate(({ s, url, name }) => {
      Object.assign(window.S, s);
      window.syncControls();
      window.shots.length = 0;
      window.shots.push({ name, url });
      window.setActiveShot(0);
      window.apply();
    }, { s: finalSettings, url: dataUrl, name: path.basename(job.abs) });

    // make sure the screenshot has actually decoded before exporting
    await page.waitForFunction(() => {
      const img = document.getElementById('shot');
      return img.complete && img.naturalWidth > 0;
    });

    const [download] = await Promise.all([
      page.waitForEvent('download', { timeout: 60000 }),
      page.click('#export'),
    ]);
    await download.saveAs(job.outPath);

    const dims = await page.evaluate(() =>
      Math.round(window.stageW * window.S.escale) + 'x' + Math.round(window.stageH * window.S.escale));
    console.log(job.outPath + '  (' + dims + ')');
  }
} finally {
  await browser.close();
}
