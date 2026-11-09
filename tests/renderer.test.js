import { describe, expect, test } from 'bun:test';
import { DOMParser } from '@xmldom/xmldom';
import { createCanvas } from '@napi-rs/canvas';
import { standaloneSvg } from '../scripts/standalone-svg.js';

function parse(svg) {
  return new DOMParser().parseFromString(svg, 'image/svg+xml');
}

function render(text, options = {}) {
  const result = Bun.spawnSync([process.execPath, 'scripts/renderer.js'], {
    cwd: new URL('..', import.meta.url).pathname,
    stdin: Buffer.from(JSON.stringify({ text, options })),
    stdout: 'pipe', stderr: 'pipe',
  });
  const payload = JSON.parse(result.stdout.toString());
  if (result.exitCode !== 0) throw new Error(payload.error);
  return payload.output;
}

describe('standalone SVG semantics', () => {
  test('resolves scoped aliases without leaking node overrides to siblings', () => {
    const output = standaloneSvg('<svg xmlns="http://www.w3.org/2000/svg" style="--base:#112233;--paint:var(--base)"><g style="--base:#ff0000"><rect id="inherited" fill="var(--paint)"/><rect id="local" fill="var(--base)"/></g><rect id="sibling" fill="var(--base)"/></svg>', {}, true);
    const doc = parse(output);
    expect(doc.getElementById('inherited').getAttribute('fill')).toBe('rgb(17, 34, 51)');
    expect(doc.getElementById('local').getAttribute('fill')).toBe('rgb(255, 0, 0)');
    expect(doc.getElementById('sibling').getAttribute('fill')).toBe('rgb(17, 34, 51)');
  });

  test('resolves nested fallbacks and modern CSS colors', () => {
    const output = standaloneSvg('<svg xmlns="http://www.w3.org/2000/svg"><rect fill="var(--missing,var(--fallback,#abcdef))" stroke="color-mix(in srgb, #000 50%, #fff)"/></svg>', {}, true);
    const rect = parse(output).getElementsByTagName('rect')[0];
    expect(rect.getAttribute('fill')).toBe('rgb(171, 205, 239)');
    expect(rect.getAttribute('stroke')).toBe('rgb(128, 128, 128)');
  });

  test('preserves currentColor inheritance', () => {
    const output = standaloneSvg('<svg xmlns="http://www.w3.org/2000/svg" color="#123456"><g><rect fill="currentColor"/></g></svg>', {}, true);
    expect(parse(output).getElementsByTagName('rect')[0].getAttribute('fill')).toBe('rgb(18, 52, 86)');
  });

  test.each(['inherit', 'initial', 'unset', 'revert'])('preserves Pele box color %s', (keyword) => {
    const doc = parse(render(`sequenceDiagram\nbox ${keyword} Group\nparticipant A\nparticipant B\nend\nA->>B: Hello`));
    expect(Array.from(doc.getElementsByTagName('*')).some((el) =>
      el.getAttribute('fill') === keyword || (el.getAttribute('style') || '').split(';').includes(`fill:${keyword}`))).toBe(true);
    expect(doc.documentElement.textContent).toContain('Hello');
  });

  test('theme background is painted and transparency omits that paint', () => {
    const source = 'flowchart LR\nA[Start] --> B[Finish]';
    const opaque = parse(render(source, { bg: '#123456', font: 'CaskaydiaMono NFP' }));
    const background = Array.from(opaque.getElementsByTagName('rect')).find((el) => el.getAttribute('class') === 'pele-background');
    expect(background.getAttribute('fill')).toBe('rgb(18, 52, 86)');
    expect(opaque.documentElement.getAttribute('style')).toContain('CaskaydiaMono NFP');
    const transparent = parse(render(source, { transparent: true }));
    expect(Array.from(transparent.getElementsByTagName('rect')).some((el) => el.getAttribute('class') === 'pele-background')).toBe(false);
  });

  test('sizes nodes to contain labels in the selected monospace font', () => {
    const label = 'iiiiiiiiiiiiiiiiiiii';
    const doc = parse(render(`flowchart LR\nA[${label}] --> B[Done]`, { font: 'monospace' }));
    const node = Array.from(doc.getElementsByTagName('g')).find((el) => el.getAttribute('data-id') === 'A');
    const box = node.getElementsByTagName('rect')[0];
    const context = createCanvas(1, 1).getContext('2d');
    context.font = '16px monospace';
    expect(Number(box.getAttribute('width'))).toBeGreaterThan(context.measureText(label).width);
    expect(node.textContent).toContain(label);
  });

  test('keeps source node styling and XML text through conversion', () => {
    const doc = parse(render('flowchart LR\nA["A & B"] --> B[Done]\nstyle A fill:#ff0000,stroke:#00ff00'));
    expect(doc.documentElement.textContent).toContain('A & B');
    const styled = Array.from(doc.getElementsByTagName('*')).filter((el) => (el.getAttribute('style') || '').includes('fill:rgb(255, 0, 0)'));
    expect(styled.some((el) => el.getAttribute('style').includes('stroke:rgb(0, 255, 0)'))).toBe(true);
  });
});
