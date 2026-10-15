import { build } from 'esbuild';
import { readFileSync, statSync } from 'node:fs';

// Viewer-request Lambda@Edge is capped at 1 MB *compressed*. Warn well before
// that, since the zip is produced later by Terraform's archive_file.
const WARN_BYTES = 700 * 1024;

// Lambda@Edge has no environment variables, so the Secrets Manager entry to
// read from is baked in at build time.
let secretId;
try {
  secretId = JSON.parse(readFileSync('SM_CONFIG_KEY.json', 'utf-8')).SecretsManagerKey;
} catch {
  console.error(
    'SM_CONFIG_KEY.json not found.\n' +
      '  cp .example.SM_CONFIG_KEY.json SM_CONFIG_KEY.json\n' +
      '  then set the Secrets Manager secret name.',
  );
  process.exit(1);
}
if (!secretId) {
  console.error('SM_CONFIG_KEY.json has no SecretsManagerKey');
  process.exit(1);
}

const result = await build({
  define: { __SECRET_ID__: JSON.stringify(secretId) },
  entryPoints: ['src/handler.ts'],
  bundle: true,
  minify: true,
  platform: 'node',
  target: 'node20',
  format: 'cjs',
  outfile: 'dist/index.js',
  // Provided by the Lambda runtime; bundling it would blow the size budget.
  external: ['@aws-sdk/*'],
  legalComments: 'none',
  metafile: true,
});

const bytes = statSync('dist/index.js').size;
const kb = (bytes / 1024).toFixed(1);

const inputs = Object.entries(result.metafile.outputs['dist/index.js'].inputs)
  .map(([file, meta]) => [file, meta.bytesInOutput])
  .sort((a, b) => b[1] - a[1])
  .slice(0, 8);

console.log(`\ndist/index.js  ${kb} KB (uncompressed)\n`);
console.log('largest contributors:');
for (const [file, size] of inputs) {
  console.log(`  ${(size / 1024).toFixed(1).padStart(8)} KB  ${file}`);
}

if (bytes > WARN_BYTES) {
  console.error(
    `\nWARNING: ${kb} KB uncompressed is close to the 1 MB compressed ceiling ` +
      `for viewer-request Lambda@Edge. Check the zip size before deploying.`,
  );
  process.exit(1);
}

console.log(`\nOK: comfortably under the 1 MB viewer-request limit.`);
