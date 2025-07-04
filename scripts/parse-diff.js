// $RUNNER_TEMP/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff from 'parse-diff';

// Read diff from stdin (piped by PowerShell)
const diff = readFileSync(0, 'utf8');          // fd 0 == stdin
const files = parseDiff(diff);

// Normalise the structure so PowerShell can `ConvertFrom-Json`
const out = files.map(f => ({
  path:  f.to === '/dev/null' ? null : f.to,
  hunks: f.chunks.map(c => ({
    header:  c.content,
    // map each added/ctx line to its new-file line number
    lineMap: c.changes
              .filter(ch => ch.type !== 'del')
              .map(ch => ch.ln)           // GitHub “line” you’ll use later
  }))
}));
console.log(JSON.stringify(out));
