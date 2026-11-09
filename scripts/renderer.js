import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
import { once } from 'node:events';

const COLOR_ROLES = ['bg', 'fg', 'line', 'accent', 'muted', 'surface', 'border'];
const OPTION_NAMES = new Set([
  ...COLOR_ROLES, 'font', 'padding', 'nodeSpacing', 'layerSpacing', 'transparent',
]);
const DARK = {
  '--pele-bg': '#100f0f',
  '--pele-fg': '#cecdc3',
  '--pele-muted': '#878580',
  '--pele-line': '#cecdc3',
  '--pele-surface': '#1c1b1a',
  '--pele-surface-alt': '#282726',
  '--pele-border': '#403e3c',
  '--pele-accent': '#4385be',
  '--pele-critical': '#d14d41',
};

function renderOptions(payload, defaultFont) {
  if (!payload || typeof payload !== 'object' || Array.isArray(payload)) {
    throw new Error('Expected a JSON object');
  }
  if (typeof payload.text !== 'string') throw new Error('text must be a Mermaid source string');
  if ((payload.format ?? 'svg') !== 'svg') throw new Error('Only SVG output is supported');
  const themeName = payload.theme ?? 'default';
  if (!['default', 'light', 'dark'].includes(themeName)) {
    throw new Error(`Unsupported theme: ${themeName}. Use default, light, dark, or resolve nvim colors in Lua.`);
  }
  const options = payload.options ?? {};
  if (typeof options !== 'object' || Array.isArray(options)) throw new Error('options must be an object');
  for (const [name, value] of Object.entries(options)) {
    if (!OPTION_NAMES.has(name)) throw new Error(`Unsupported render option: ${name}`);
    if (value == null) continue;
    if (COLOR_ROLES.includes(name) || name === 'font') {
      if (typeof value !== 'string' || !value.trim()) throw new Error(`${name} must be a nonempty string`);
      if (/[;{}<>]/.test(value) || value.includes('var(')) {
        throw new Error(`${name} must be a literal CSS value, not a declaration or CSS variable`);
      }
    } else if (name === 'transparent') {
      if (typeof value !== 'boolean') throw new Error('transparent must be a boolean');
    } else if (!Number.isFinite(value) || (name === 'padding' ? value < 0 : value <= 0) || value > 2000) {
      throw new Error(`${name} must be ${name === 'padding' ? 'between 0 and' : 'greater than 0 and at most'} 2000`);
    }
  }

  const theme = themeName === 'dark' ? { ...DARK } : {};
  for (const name of COLOR_ROLES) {
    if (options[name] != null) theme[`--pele-${name}`] = options[name];
  }
  if (options.surface != null) theme['--pele-surface-alt'] = options.surface;
  const spacing = {};
  if (options.nodeSpacing != null) spacing.nodeSpacing = options.nodeSpacing;
  if (options.layerSpacing != null) spacing.rankSpacing = options.layerSpacing;
  const config = {};
  // These are Pele's layered layouts. Sequence/charts use their own layout
  // settings, which can be supplied through Mermaid frontmatter/directives.
  for (const type of ['flowchart', 'class', 'state', 'er', 'agentflow']) config[type] = { ...spacing };
  return {
    theme,
    transparent: options.transparent ?? false,
    options: {
      fontFamily: options.font ?? defaultFont,
      fontFamilyMono: options.font ?? defaultFont,
      padding: options.padding ?? 8,
      responsive: false,
      autoDirection: false,
      config,
    },
  };
}

async function initializeRenderer() {
  let DEFAULT_FONT, embedBundledFonts, registerBundledFonts, outlineSvg;
  let render;
  let standaloneSvg;
  let createCanvas;
  let GlobalFonts, convertSVGTextToPath;
  try {
    ({ render } = await import('pele'));
    ({ standaloneSvg } = await import('./standalone-svg.js'));
    ({ createCanvas, GlobalFonts, convertSVGTextToPath } = await import('@napi-rs/canvas'));
    ({ DEFAULT_FONT, embedBundledFonts, registerBundledFonts, outlineSvg } = await import('./fonts.js'));
  } catch (error) {
    throw new Error(`Renderer dependencies unavailable; run bun install --frozen-lockfile in nvim-pele-mermaid: ${error.message}`);
  }
  registerBundledFonts(GlobalFonts);
  const context = createCanvas(1, 1).getContext('2d');
  let measuredFont;
  return function renderRequest(payload) {
    if (payload?.operation === 'outline') {
      return { output: outlineSvg(payload.svg, convertSVGTextToPath) };
    }
    const settings = renderOptions(payload, DEFAULT_FONT);
    settings.options.measurer = {
      width(text, size, style) {
        const family = style & 4 ? settings.options.fontFamilyMono : settings.options.fontFamily;
        const font = `${style & 2 ? 'italic ' : ''}${style & 1 ? 'bold ' : ''}${size}px ${family}`;
        if (font !== measuredFont) {
          context.font = font;
          measuredFont = font;
        }
        return context.measureText(text).width;
      },
    };
    const { svg } = render(payload.text, settings.options);
    const standalone = standaloneSvg(svg, settings.theme, settings.transparent);
    const output = payload.embed_fonts === false ? standalone : embedBundledFonts(standalone);
    return { output };
  };
}

function parseInput(input) {
  try {
    return JSON.parse(input);
  } catch {
    throw new Error('Invalid JSON input');
  }
}

function errorResult(error) {
  return { error: error instanceof Error ? error.message : String(error) };
}

async function serve(renderRequest) {
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of lines) {
    let id = null;
    let result;
    try {
      const envelope = parseInput(line);
      if (!envelope || typeof envelope !== 'object' || Array.isArray(envelope)
        || typeof envelope.id !== 'number' || !Number.isFinite(envelope.id)) {
        throw new Error('Expected a JSON object with a numeric id and request');
      }
      id = envelope.id;
      result = renderRequest(envelope.request);
    } catch (error) {
      result = errorResult(error);
    }
    if (!process.stdout.write(`${JSON.stringify({ id, result })}\n`)) {
      await once(process.stdout, 'drain');
    }
  }
}

const server = process.argv.includes('--server');
try {
  if (!process.versions.bun && Number(process.versions.node.split('.')[0]) < 20) {
    throw new Error('Pele requires Node.js >=20; upgrade Node.js or use Bun');
  }
  if (server) {
    // Attach the input reader after initialization; stdin remains paused until then.
    await serve(await initializeRenderer());
  } else {
    const payload = parseInput(readFileSync(0, 'utf8'));
    const renderRequest = await initializeRenderer();
    process.stdout.write(JSON.stringify(renderRequest(payload)));
  }
} catch (error) {
  const result = errorResult(error);
  process.stdout.write(server
    ? `${JSON.stringify({ id: null, result })}\n`
    : JSON.stringify(result));
  process.exitCode = 1;
}
