import { describe, expect, test } from 'bun:test';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DOMParser } from '@xmldom/xmldom';
import { embedBundledFonts } from '../scripts/fonts.js';

const root = new URL('..', import.meta.url).pathname;
const parse = (svg) => new DOMParser().parseFromString(svg, 'image/svg+xml');
const withoutSystemFonts = { ...process.env, DISABLE_SYSTEM_FONTS_LOAD: '1' };

function render(options = {}) {
  const result = Bun.spawnSync([process.execPath, 'scripts/renderer.js'], {
    cwd: root, env: withoutSystemFonts,
    stdin: Buffer.from(JSON.stringify({ text: 'flowchart LR\nA[Maple iii WWW] --> B[Done]', options })),
    stdout: 'pipe', stderr: 'pipe',
  });
  const response = JSON.parse(result.stdout.toString());
  expect(result.exitCode, response.error).toBe(0);
  return response.output;
}

describe('bundled Maple Mono NF', () => {
  test('uses the bundled default without system fonts and embeds portable text', () => {
    const document = parse(render());
    expect(document.documentElement.getAttribute('style')).toContain('Maple Mono NF');
    expect(document.getElementsByTagName('text').length).toBeGreaterThan(0);
    const css = Array.from(document.getElementsByTagName('style')).map((node) => node.textContent).join('');
    expect(css).toContain('data:font/woff2;base64,');
    expect(document.getElementsByTagName('metadata')[0].textContent).toContain('SIL OPEN FONT LICENSE');
  });

  test('retains custom family overrides without embedding unused Maple faces', () => {
    const document = parse(render({ font: 'monospace' }));
    expect(document.documentElement.getAttribute('style')).toContain('monospace');
    expect(Array.from(document.getElementsByTagName('style')).some((node) => node.hasAttribute('data-pele-fonts'))).toBe(false);
  });

  test('embeds all four requested faces with inherited weight and style', () => {
    const svg = '<svg xmlns="http://www.w3.org/2000/svg" font-family="Maple Mono NF"><text>Regular</text><g font-weight="700"><text>Bold</text><text font-style="italic">Bold italic</text></g><text style="font-style:italic">Italic</text></svg>';
    const css = parse(embedBundledFonts(svg)).getElementsByTagName('style')[0].textContent;
    for (const style of ['normal', 'italic']) {
      for (const weight of [400, 700]) expect(css).toContain(`font-style:${style};font-weight:${weight};`);
    }
  });

  test('outlines a separate copy without system fonts and preserves export text', () => {
    const directory = mkdtempSync(join(tmpdir(), 'pele-fonts-'));
    try {
      const original = render();
      const input = join(directory, 'original.svg');
      const output = join(directory, 'outlined.svg');
      writeFileSync(input, original);
      const result = Bun.spawnSync([process.execPath, 'scripts/outline-svg.js', input, output], {
        cwd: root, env: withoutSystemFonts, stdout: 'pipe', stderr: 'pipe',
      });
      expect(result.exitCode, result.stderr.toString()).toBe(0);
      const outlined = parse(readFileSync(output, 'utf8'));
      expect(outlined.getElementsByTagName('text').length).toBe(0);
      expect(readFileSync(input, 'utf8')).toBe(original);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  });
});
