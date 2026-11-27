import { prepareNativeAssets } from '../scripts/prepare-native.mjs';

await prepareNativeAssets(new URL('web/', import.meta.url));
