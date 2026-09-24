// Stages the built mockup for publishing:
//   design/.deploy/index.html        served by the Cloudflare Worker (wrangler deploy)
//   design/.artifact/jormungand.html the same page without the document wrapper, published
//                                    as a claude.ai Artifact (its host adds doctype/head/body)
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const dir = join(root, '.deploy');
const html = readFileSync(join(root, 'main_screen.html'), 'utf8');
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, 'index.html'), html);
mkdirSync(join(root, '.artifact'), { recursive: true });
writeFileSync(join(root, '.artifact', 'jormungand.html'), html
  .replace(/<!doctype html>\s*|<\/?html[^>]*>\s*|<\/?head>\s*|<\/?body[^>]*>\s*|<meta [^>]*>\s*/gi, ''));
console.log('staged design/.deploy/index.html, design/.artifact/jormungand.html');
