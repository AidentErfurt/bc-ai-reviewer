// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff          from 'parse-diff';

/** Read the full unified diff from stdin */
const rawDiff = readFileSync(0, 'utf8');
const files   = parseDiff(rawDiff);

const result = files.map(f => {
  // 1) derive the file path
  const rawPath = f.to !== '/dev/null' ? f.to : f.from;
  const path    = rawPath.replace(/^[ab]\//, '');

  // 2) rebuild each hunk’s string
  const diff = f.chunks
    .map(chunk => {
      const header = `@@ ${chunk.content} @@`;
      const body   = chunk.chunks  // here: chunk.changes holds all lines
        ? chunk.changes.map(c => c.content).join('\n')
        : '';
      return [header, body].filter(Boolean).join('\n');
    })
    .join('\n\n');

  // 3) create lineMap: for each add|normal change, record its ln2
  const lineMap = [];
  for (const chunk of f.chunks) {
    for (const change of chunk.changes) {
      if ((change.type === 'add' || change.type === 'normal') && typeof change.ln2 === 'number') {
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
