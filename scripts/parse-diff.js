// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff          from 'parse-diff';

/** Read the full unified diff from stdin */
const rawDiff = readFileSync(0, 'utf8');
const files   = parseDiff(rawDiff);

// 1) Ensure every change has ln1, ln2, and unified ln
files.forEach(file => {
  file.chunks.forEach(chunk => {
    chunk.changes.forEach(change => {
      // deletions: alias ln → ln1
      if (change.type === 'del'  && typeof change.ln === 'number') change.ln1 = change.ln;
      // additions: alias ln → ln2
      if (change.type === 'add'  && typeof change.ln === 'number') change.ln2 = change.ln;
      // context lines already have ln1 & ln2

      // make sure both props exist on every change
      if (typeof change.ln1 !== 'number') change.ln1 = null;
      if (typeof change.ln2 !== 'number') change.ln2 = null;

      // unified ln: prefer new‐file (ln2), else old‐file (ln1)
      change.ln = (typeof change.ln2 === 'number') ? change.ln2 : change.ln1;
    });
  });
});

const result = files.map(f => {
  // derive repo‐relative path
  const rawPath = f.to !== '/dev/null' ? f.to : f.from;
  const path    = rawPath.replace(/^[ab]\//, '');

  // rebuild each hunk
  const diff = f.chunks
    .map(chunk => {
      const header = `@@ ${chunk.content} @@`;
      const body   = chunk.changes.map(c => c.content).join('\n');
      return [header, body].filter(Boolean).join('\n');
    })
    .join('\n\n');

  // build lineMap from every add|normal’s ln2
  const lineMap = [];
  for (const chunk of f.chunks) {
    for (const change of chunk.changes) {
      if ((change.type === 'add' || change.type === 'normal')
          && typeof change.ln2 === 'number') {
        lineMap.push(change.ln2);
      }
    }
  }

  return { path, diff, chunks: f.chunks, lineMap };
});

console.log(JSON.stringify(result));
