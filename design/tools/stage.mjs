// Copies the built mockup into design/.deploy/ as index.html for `wrangler deploy`.
import { mkdirSync, copyFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
mkdirSync(join(root, '.deploy'), { recursive: true });
copyFileSync(join(root, 'main_screen.html'), join(root, '.deploy', 'index.html'));
console.log('staged design/.deploy/index.html');
