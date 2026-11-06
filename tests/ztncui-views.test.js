#!/usr/bin/env node
/*
  Compile every Pug view in the overlay. This catches syntax errors and broken
  layout inheritance without needing a running controller or a database.
  Requires `npm ci --omit=dev --ignore-scripts` in patch/ztncui first.
*/

const fs = require('fs');
const path = require('path');

const root = path.join(__dirname, '..', 'patch', 'ztncui');
let pug;
try {
  pug = require(path.join(root, 'node_modules', 'pug'));
} catch (err) {
  console.error('Missing pug. Run: cd patch/ztncui && npm ci --omit=dev --ignore-scripts');
  process.exit(1);
}

const viewsDir = path.join(root, 'views');
const files = fs.readdirSync(viewsDir).filter((name) => name.endsWith('.pug')).sort();
if (files.length === 0) {
  console.error('No Pug views found in ' + viewsDir);
  process.exit(1);
}

let failed = 0;
for (const file of files) {
  try {
    pug.compileFile(path.join(viewsDir, file));
    console.log('OK ' + file);
  } catch (err) {
    failed++;
    console.error('FAIL ' + file + ': ' + err.message);
  }
}

if (failed) {
  console.error(failed + ' view(s) failed to compile');
  process.exit(1);
}

// Mobile data tables rely on data-label attributes for the card layout.
const labelled = ['networks.pug', 'network_detail.pug', 'routes.pug', 'ipAssignmentPools.pug', 'ipAssignments.pug', 'users.pug'];
for (const file of labelled) {
  const markup = fs.readFileSync(path.join(viewsDir, file), 'utf8');
  if (!markup.includes('data-label=')) {
    console.error('Missing data-label in ' + file);
    process.exit(1);
  }
}
const css = fs.readFileSync(path.join(root, 'public', 'stylesheets', 'app.css'), 'utf8');
if (!css.includes('@media (max-width: 720px)') || !css.includes('attr(data-label)')) {
  console.error('Missing mobile table rules in app.css');
  process.exit(1);
}
console.log('Compiled ' + files.length + ' views; mobile data-label rules present');
