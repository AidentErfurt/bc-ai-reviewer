// scripts/parse-diff.js
// Minimal wrapper that reads a unified diff from stdin and outputs JSON parsed by 'parse-diff'
// Usage: node scripts/parse-diff.js < diff.patch

const fs = require('fs');

let parse;
try {
  parse = require('parse-diff');
} catch (e) {
  // Try to require from CWD (installed by the action) as fallback
  try {
    const { createRequire } = require('module');
    const cwdRequire = createRequire(process.cwd() + '/');
    parse = cwdRequire('parse-diff');
  } catch (err) {
    console.error('Could not load "parse-diff" module. Please run `npm install --no-save parse-diff` in the action step.');
    console.error(err && err.stack ? err.stack : err);
    process.exit(2);
  }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', c => buf += c);
process.stdin.on('end', () => {
  try {
    const files = parse(buf || '');
    process.stdout.write(JSON.stringify(files));
  } catch (e) {
    console.error(e && e.stack ? e.stack : e);
    process.exit(1);
  }
});
