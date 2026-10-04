// Shared bits of the generators in app/tool.
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

export const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..');

// `dart format` works with the standalone Dart SDK (no Flutter needed). Silent when dart is missing.
export function dartFormat(...files) {
  const r = spawnSync('dart', ['format', ...files], { stdio: 'ignore' });
  if (r.error) console.warn('dart not found on PATH — generated Dart is left unformatted');
}
