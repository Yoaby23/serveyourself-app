import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { prepareNativeAssets } from '../scripts/prepare-native.mjs';

const web = new URL('web/', import.meta.url);
await prepareNativeAssets(web);
const bridge = await readFile(new URL('bridge.js', import.meta.url), 'utf8');
const app = new URL('app.js', web);
await writeFile(app, `${bridge}\n${await readFile(app, 'utf8')}`);
const drawable = new URL('android/app/src/main/res/drawable-nodpi/', import.meta.url);
await mkdir(drawable, { recursive: true });
await copyFile(new URL('app-icon-512.png', web), new URL('brand_icon.png', drawable));
