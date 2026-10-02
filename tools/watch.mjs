#!/usr/bin/env node
import { watch } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
const cwd = fileURLToPath(new URL('..', import.meta.url));
let timer, running = false, pending = false;
const run = (command, args = []) => new Promise((resolve, reject) => {
  const child = spawn(command, args, { cwd, stdio: 'inherit' });
  child.on('error', reject);
  child.on('exit', code => code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`)));
});
async function refresh() {
  if (running) { pending = true; return; }
  running = true;
  try {
    await run('tools/build.sh');
    await run('tools/install.sh');
    await run('/usr/bin/open', [join(homedir(), 'Applications', 'ClipEdge.app'), '--args', '--no-permission-prompt']);
    console.log('ClipEdge rebuilt and reopened.');
  } catch (error) { console.error(error.message); }
  finally { running = false; if (pending) { pending = false; refresh(); } }
}
watch(cwd, (_, name) => {
  if (!name?.endsWith('.swift')) return;
  clearTimeout(timer); timer = setTimeout(refresh, 400);
});
console.log('Watching Swift source; edits rebuild and reopen the installed app. Ctrl-C stops watching.');
refresh();
