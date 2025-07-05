// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff from 'parse-diff';

// Read the full unified diff from stdin
const rawDiff = readFileSync(0, 'utf8');
const files = parseDiff(rawDiff);

const result = files.map(f => {
  // Determine the "after" path (or "before" if deleted)
  const path = (f.to !== '/dev/null' ? f.to : f.from)
    .replace(/^b\//, '')
    .replace(/^a\//, '');

  // Reconstruct each hunk: header + its changed lines
  const hunks = f.chunks.map(chunk => {
    const header = chunk.content; // the "@@ -.. +.. @@" line
    const lines = chunk.changes.map(c => c.content).join('\n');
    return [header, lines].filter(Boolean).join('\n');
  }).join('\n');

  return {
    path,
    diff: hunks
  };
});

console.log(JSON.stringify(result));
