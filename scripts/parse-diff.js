// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff from 'parse-diff';

// Read the full unified diff from stdin (fd 0)
const diff = readFileSync(0, 'utf8');
const files = parseDiff(diff);

// Emit only the file path and full diff text
const result = files.map(f => {
  const path = (f.to !== '/dev/null' ? f.to : f.from)
                 .replace(/^b\//, '')
                 .replace(/^a\//, '');
  return {
    path,
    diff: f.diff
  };
});

console.log(JSON.stringify(result));
