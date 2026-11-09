import { readFileSync } from 'node:fs';
import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { fileURLToPath } from 'node:url';

export const DEFAULT_FONT = 'Maple Mono NF';
export const FONT_FILES = ['Regular', 'Bold', 'Italic', 'BoldItalic'].map((style) =>
  fileURLToPath(new URL(`../assets/fonts/MapleMono-NF-${style}.ttf`, import.meta.url)));

export function registerBundledFonts(globalFonts) {
  for (const path of FONT_FILES) {
    if (!globalFonts.registerFromPath(path, DEFAULT_FONT)) {
      throw new Error(`Cannot load bundled ${DEFAULT_FONT} font: ${path}`);
    }
  }
}

// Embed only faces actually used by text. Native rasterizers generally ignore
// web fonts; outline-svg.js independently loads the TTFs for those consumers.
export function embedBundledFonts(svg) {
  const document = new DOMParser().parseFromString(svg, 'image/svg+xml');
  const faces = new Set();
  const visit = (element, inherited) => {
    const font = { ...inherited };
    for (const name of ['font-family', 'font-weight', 'font-style']) {
      if (element.hasAttribute(name)) font[name] = element.getAttribute(name);
    }
    for (const declaration of (element.getAttribute('style') || '').split(';')) {
      const colon = declaration.indexOf(':');
      const name = declaration.slice(0, colon).trim();
      if (['font-family', 'font-weight', 'font-style'].includes(name)) {
        font[name] = declaration.slice(colon + 1).trim();
      }
    }
    if (['text', 'tspan'].includes(element.localName) && (font['font-family'] || '').includes(DEFAULT_FONT)) {
      const bold = /bold/.test(font['font-weight']) || Number(font['font-weight']) >= 600;
      const italic = /italic|oblique/.test(font['font-style']);
      faces.add((bold ? 1 : 0) + (italic ? 2 : 0));
    }
    for (const child of Array.from(element.childNodes)) {
      if (child.nodeType === 1) visit(child, font);
    }
  };
  visit(document.documentElement, {});
  if (!faces.size) return svg;
  const style = document.createElementNS('http://www.w3.org/2000/svg', 'style');
  style.setAttribute('data-pele-fonts', 'bundled');
  style.textContent = Array.from(faces, (index) => {
    const data = readFileSync(FONT_FILES[index].replace(/\.ttf$/, '.woff2')).toString('base64');
    return `@font-face{font-family:"${DEFAULT_FONT}";font-style:${index & 2 ? 'italic' : 'normal'};font-weight:${index & 1 ? 700 : 400};src:url(data:font/woff2;base64,${data}) format("woff2")}`;
  }).join('\n');
  const license = document.createElementNS('http://www.w3.org/2000/svg', 'metadata');
  license.setAttribute('data-pele-fonts', 'license');
  license.textContent = readFileSync(new URL('../assets/fonts/LICENSE.txt', import.meta.url), 'utf8');
  const root = document.documentElement;
  root.insertBefore(style, root.firstChild);
  root.insertBefore(license, root.firstChild);
  return new XMLSerializer().serializeToString(document);
}

export function outlineSvg(svg, convertSVGTextToPath) {
  if (typeof svg !== 'string') throw new Error('SVG input must be a string');
  const document = new DOMParser().parseFromString(svg, 'image/svg+xml');
  for (const element of Array.from(document.getElementsByTagName('*'))) {
    if (element.hasAttribute('data-pele-fonts')) element.parentNode.removeChild(element);
  }
  const outlined = convertSVGTextToPath(new XMLSerializer().serializeToString(document)).toString('utf8');
  const result = new DOMParser().parseFromString(outlined, 'image/svg+xml');
  if (result.documentElement.localName !== 'svg' || result.getElementsByTagName('text').length) {
    throw new Error('SVG text outlining failed; refusing a system-font fallback');
  }
  return outlined;
}
