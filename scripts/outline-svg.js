import { readFileSync, writeFileSync } from 'node:fs';
import { GlobalFonts, convertSVGTextToPath } from '@napi-rs/canvas';
import { registerBundledFonts, outlineSvg } from './fonts.js';

try {
  const [input, output] = process.argv.slice(2);
  if (!input || !output) throw new Error('Usage: outline-svg.js input.svg output.svg');
  registerBundledFonts(GlobalFonts);
  writeFileSync(output, outlineSvg(readFileSync(input, 'utf8'), convertSVGTextToPath));
} catch (error) {
  console.error(`SVG font preparation failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
}
