// scripts/parse-diff.js
import { readFileSync } from 'fs';
import parseDiff from 'parse-diff';


// Read the full unified diff from stdin (fd 0)
const diff = readFileSync(0, 'utf8');
const files = parseDiff(diff);
const headerLines = [`--- a/${path}`, `+++ b/${path}`];
headerLines.forEach(l => { lines.push(l); pos++; });

// Normalize and emit each file's path, diff text, and lineMap for PowerShell
const result = files.map(f => {
  // Pick whichever side isnt /dev/null
  const path = (f.to !== '/dev/null' ? f.to : f.from).replace(/^b\//,'').replace(/^a\//,'');

  let pos     = 0;            // 1-based position inside the patch
  const map   = {};           // new-file line  ->  position
  const lines = [];           // full patch text for debugging

  f.chunks.forEach(chunk => {
    // hunk header counts as 1 position
    lines.push(chunk.content);
    pos++;

    chunk.changes.forEach(ch => {
      lines.push(ch.content);
      pos++;

      // GitHub only accepts comments on lines that exist in the “after” file
      if (ch.type !== 'del' && ch.ln !== undefined) {
        map[ch.ln] = pos;     // ln = line number in the new file
      }
    });
  });

  return { path, diff: lines.join('\n'), lineMap: map };
});

console.log(JSON.stringify(result));
