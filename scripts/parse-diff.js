// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff from 'parse-diff';

/** Read the full unified diff from stdin */
const rawDiff = readFileSync(0, 'utf8');
const files   = parseDiff(rawDiff);

// Ensure each change has ln1, ln2 and a unified ln alias
files.forEach(file => {
  file.chunks.forEach(chunk => {
    chunk.changes.forEach(change => {
      // Populate ln1 for deletions
      if (change.type === 'del' && typeof change.ln === 'number') {
        change.ln1 = change.ln;
      }
      // Populate ln2 for additions
      if (change.type === 'add' && typeof change.ln === 'number') {
        change.ln2 = change.ln;
      }
      // For normal/context lines, both ln1 and ln2 should already exist
      // Create unified ln: prefer new-file line (ln2) if present, else old-file line (ln1)
      change.ln = (typeof change.ln2 === 'number')
                  ? change.ln2
                  : change.ln1;
    });
  });
});

const result = files.map(f => {
  // 1) derive the file path
  const rawPath = f.to !== '/dev/null' ? f.to : f.from;
  const path    = rawPath.replace(/^[ab]\//, '');

  // 2) rebuild each hunk’s string
  const diff = f.chunks
    .map(chunk => {
      const header = `@@ ${chunk.content} @@`;
      const body   = chunk.changes.map(c => c.content).join('\n');
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
