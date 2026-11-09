import { DOMParser, XMLSerializer } from '@xmldom/xmldom';
import { convert, resolve, utils } from '@asamuzakjp/css-color';
import { tokenize } from '@csstools/css-tokenizer';
import { isFunctionNode, isSimpleBlockNode, parseListOfComponentValues } from '@csstools/css-parser-algorithms';

const SVG_NS = 'http://www.w3.org/2000/svg';
const PAINT = new Set(['fill', 'stroke', 'color', 'stop-color', 'flood-color', 'lighting-color']);
const CSS_WIDE = new Set(['inherit', 'initial', 'unset', 'revert', 'revert-layer']);
const PRESENTATION = new Set([
  ...PAINT, 'font-family', 'font-size', 'font-weight', 'font-style',
  'fill-opacity', 'stroke-opacity', 'opacity', 'stroke-width', 'stroke-dasharray',
  'stroke-dashoffset', 'rx', 'ry',
]);

// Resolve complete CSS component values: the color library's cssVar helper only
// retains identifier fallbacks, losing hashes, dimensions, and quoted fonts.
// Its color conversion remains useful after variables have been substituted.
function variables(value, scope, resolving = new Set()) {
  if (!value.includes('var(')) return value;
  const parse = (css) => parseListOfComponentValues(tokenize({ css }), {
    onParseError: (error) => { throw error; },
  });
  const expand = (nodes) => nodes.flatMap((node) => {
    if (isFunctionNode(node) && node.getName() === 'var') {
      const comma = node.value.findIndex((part) => part.toString() === ',');
      const name = (comma < 0 ? node.value : node.value.slice(0, comma))
        .map((part) => part.toString()).join('').trim();
      if (Object.hasOwn(scope, name)) {
        if (resolving.has(name)) throw new Error(`Cyclic SVG CSS variable: ${name}`);
        const next = new Set(resolving);
        next.add(name);
        return parse(variables(scope[name], scope, next));
      }
      if (comma >= 0) return expand(node.value.slice(comma + 1));
      throw new Error(`Undefined SVG CSS variable: ${name}`);
    }
    if (isFunctionNode(node) || isSimpleBlockNode(node)) node.value = expand(node.value);
    return [node];
  });
  return expand(parse(value)).map((node) => node.toString()).join('');
}

function color(value, currentColor) {
  if (CSS_WIDE.has(value.toLowerCase())) return value.toLowerCase();
  if (value === 'none' || value.startsWith('url(') || value.startsWith('context-')) return value;
  if (!utils.isColor(value)) throw new Error(`Unsupported SVG color: ${value}`);
  // Conversion alone does not compute currentColor; resolve CSS context first.
  const resolved = resolve(value, { currentColor });
  if (!resolved) throw new Error(`Cannot resolve SVG color: ${value}`);
  const [r, g, b, a] = convert.colorToRgb(resolved);
  const channel = (n) => Math.round(Math.max(0, Math.min(255, n)));
  return a === 1
    ? `rgb(${channel(r)}, ${channel(g)}, ${channel(b)})`
    : `rgba(${channel(r)}, ${channel(g)}, ${channel(b)}, ${a})`;
}

// Pele emits sanitized inline declarations (no stylesheets, semicolons in values,
// or external CSS). Parse those declarations, not the SVG with regular expressions.
function declarations(style) {
  return style.split(';').filter((part) => part.trim()).map((part) => {
    const at = part.indexOf(':');
    if (at < 1) throw new Error(`Invalid SVG style declaration: ${part}`);
    return [part.slice(0, at).trim(), part.slice(at + 1).trim()];
  });
}

/** Freeze Pele's inline CSS into a standalone SVG for resvg/librsvg.
 * Custom properties are computed on their defining element before inheritance;
 * local palette/style overrides therefore do not accidentally affect siblings.
 */
export function standaloneSvg(svg, theme, transparent = false) {
  const document = new DOMParser({
    onError: (level, message) => { throw new Error(`Invalid Pele SVG (${level}): ${message}`); },
  }).parseFromString(svg, 'image/svg+xml');
  const root = document.documentElement;
  if (root.localName !== 'svg') throw new Error('Pele did not return an SVG document');

  const visit = (element, inherited, inheritedColor) => {
    const style = declarations(element.getAttribute('style') || '');
    const scope = { ...inherited };
    for (const [name, value] of style) {
      if (name.startsWith('--')) scope[name] = value;
    }
    // Resolve against all declarations on this element, including forward refs.
    const computed = { ...scope };
    for (const [name, value] of Object.entries(scope)) computed[name] = variables(value, scope);

    const ownColor = style.findLast(([name]) => name === 'color')?.[1]
      ?? element.getAttribute('color') ?? inheritedColor;
    const resolvedColor = ownColor ? variables(ownColor, computed) : 'inherit';
    const currentColor = CSS_WIDE.has(resolvedColor.toLowerCase())
      ? (resolvedColor.toLowerCase() === 'initial' ? '#000000' : inheritedColor)
      : color(resolvedColor, inheritedColor);

    for (const name of PRESENTATION) {
      if (!element.hasAttribute(name)) continue;
      let value = variables(element.getAttribute(name), computed);
      if (PAINT.has(name)) value = color(value, currentColor);
      element.setAttribute(name, value);
    }
    const resolvedStyle = [];
    for (const [name, original] of style) {
      if (name.startsWith('--')) continue;
      let value = variables(original, computed);
      if (PAINT.has(name)) value = color(value, currentColor);
      // SVG 1.1 rasterizers do not uniformly support CSS geometry properties.
      if (name === 'rx' || name === 'ry') {
        element.setAttribute(name, value);
      } else if (name === 'font') {
        // Pele's root shorthand is always "<size>px sans-serif". Its separate
        // font-family declaration carries the measured/user-selected family.
        const match = /^(\d+(?:\.\d+)?)px sans-serif$/.exec(value);
        if (!match) throw new Error(`Unsupported Pele font shorthand: ${value}`);
        element.setAttribute('font-size', match[1]);
      } else {
        resolvedStyle.push(`${name}:${value}`);
      }
    }
    if (resolvedStyle.length) element.setAttribute('style', resolvedStyle.join(';'));
    else element.removeAttribute('style');

    for (let child = element.firstChild; child; child = child.nextSibling) {
      if (child.nodeType === 1) visit(child, computed, currentColor);
    }
  };

  visit(root, theme, '#1f1f1f');
  if (!transparent) {
    // CSS background on an SVG root is not painted by many rasterizers.
    const background = document.createElementNS(SVG_NS, 'rect');
    background.setAttribute('class', 'pele-background');
    background.setAttribute('width', '100%');
    background.setAttribute('height', '100%');
    background.setAttribute('fill', color(theme['--pele-bg'] ?? '#ffffff', '#1f1f1f'));
    root.insertBefore(background, root.firstChild);
  }
  return new XMLSerializer().serializeToString(document);
}
