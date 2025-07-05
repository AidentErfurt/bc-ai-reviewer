// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff          from 'parse-diff';

/** Read the full unified diff from stdin */
const rawDiff = readFileSync(0, 'utf8');
const files   = parseDiff(rawDiff);

// 1) Make sure every change object has ln1, ln2 and a unified ln
files.forEach(file => {
  file.chunks.forEach(chunk => {
    chunk.changes.forEach(change => {
      // for deletions, parse-diff gives you `change.ln`, so alias it to ln1
      if (change.type === 'del' && typeof change.ln === 'number') {
        change.ln1 = change.ln;
      }
      // for additions, alias ln → ln2
      if (change.type === 'add' && typeof change.ln === 'number') {
        change.ln2 = change.ln;
      }
      // context/"normal" lines already have ln1 & ln2
      // now give everyone a unified ln (prefer ln2 if present)
      change.ln = (typeof change.ln2 === 'number') ? change.ln2 : change.ln1;
    });
  });
});

const result = files.map(f => {
  // derive the real repo path
  const rawPath = f.to !== '/dev/null' ? f.to : f.from;
  const path    = rawPath.replace(/^[ab]\//, '');

  // rebuild each hunk: header + all changed lines
  const diff = f.chunks
    .map(chunk => {
      const header = `@@ ${chunk.content} @@`;
      const body   = chunk.changes.map(c => c.content).join('\n');
      return [header, body].filter(Boolean).join('\n');
    })
    .join('\n\n');

  // build lineMap = every new‐file line (ln2) for add & context lines
  const lineMap = [];
  for (const chunk of f.chunks) {
    for (const change of chunk.changes) {
      if ((change.type === 'add' || change.type === 'normal')
          && typeof change.ln2 === 'number') {
        lineMap.push(change.ln2);
      }
    }
  }

  return {
    path,
    diff,
    chunks: f.chunks,
    lineMap
  };
});

console.log(JSON.stringify(result));
