// scripts/parse-diff.js

import { readFileSync } from 'fs';
import parseDiff from 'parse-diff';

// Read the full unified diff from stdin (fd 0)
const diff = readFileSync(0, 'utf8');
const files = parseDiff(diff);

// Normalize and emit each file's path, diff text, and lineMap for PowerShell
const out = files.map(f => {
  const path = f.to === '/dev/null' ? null : f.to;

  // Construct the unified diff snippet for this file
  const diffLines = f.chunks.flatMap(chunk => [
    chunk.content,                  // the "@@ -a,b +c,d @@" header
    ...chunk.changes.map(ch => ch.content) // each line with its +/‑/space prefix
  ]);

  // Build an array of new-file line numbers for inline comment mapping
  const lineMap = f.chunks
    .flatMap(chunk => chunk.changes)
    .filter(ch => ch.type !== 'del')
    .map(ch => ch.ln);

  return {
    path,
    diff: diffLines.join('\n'),
    lineMap
  };
});

// Output JSON for PowerShell ConvertFrom-Json
console.log(JSON.stringify(out));
