import fs from 'node:fs';
import vm from 'node:vm';
const window={serveYourself:{escapeHtml:value=>String(value)}};vm.runInNewContext(fs.readFileSync(new URL('../product-variations.js',import.meta.url),'utf8'),{window,Event,crypto});
export const ProductVariations=window.ProductVariations;
