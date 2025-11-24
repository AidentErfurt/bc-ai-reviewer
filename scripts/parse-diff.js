// scripts/parse-diff.js
// Compatible wrapper: parses unified diff from stdin and emits an enriched JSON
// This mirrors the older working behavior: normalizes ln1/ln2, provides a repo-relative
// path, builds a compact diff string per file and a lineMap of added/normal ln2 numbers.

const fs = require('fs');

let parse;
try {
  parse = require('parse-diff');
} catch (e) {
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

    // Post-process: ensure ln1/ln2 exist and compute unified ln
    files.forEach(file => {
      file.chunks.forEach(chunk => {
        chunk.changes.forEach(change => {
          // deletions: alias ln -> ln1
          if (change.type === 'del' && typeof change.ln === 'number') change.ln1 = change.ln;
          // additions: alias ln -> ln2
          if (change.type === 'add' && typeof change.ln === 'number') change.ln2 = change.ln;
          if (typeof change.ln1 !== 'number') change.ln1 = null;
          if (typeof change.ln2 !== 'number') change.ln2 = null;
          // unified ln: prefer new-file (ln2), else old-file (ln1)
          change.ln = (typeof change.ln2 === 'number') ? change.ln2 : change.ln1;
        });
      });
    });

    const result = files.map(f => {
      // derive repo-relative path (prefer f.to unless /dev/null)
      const rawPath = (f.to && f.to !== '/dev/null') ? f.to : f.from;
      // strip leading a/ or b/ if present
      const path = rawPath ? rawPath.replace(/^[ab]\//, '') : rawPath;

      // rebuild each hunk into a compact diff text
      const diff = (f.chunks || [])
        .map(chunk => {
          const header = `@@ ${chunk.content} @@`;
          const body = (chunk.changes || []).map(c => c.content).join('\n');
          return [header, body].filter(Boolean).join('\n');
        })
        .filter(Boolean)
        .join('\n\n');

      // build lineMap from every add|normal's ln2
      const lineMap = [];
      for (const chunk of (f.chunks || [])) {
        for (const change of (chunk.changes || [])) {
          if ((change.type === 'add' || change.type === 'normal') && typeof change.ln2 === 'number') {
            lineMap.push(change.ln2);
          }
        }
      }

      return { path, diff, chunks: f.chunks, lineMap };
    });

    process.stdout.write(JSON.stringify(result));
  } catch (e) {
    console.error(e && e.stack ? e.stack : e);
    process.exit(1);
  }
});
