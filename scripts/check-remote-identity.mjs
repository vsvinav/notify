import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { copyFileSync, mkdtempSync, chmodSync, rmSync, rmdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

if (process.argv.length !== 3 || process.argv[2] !== '--temporary-keychain-test') {
  throw new Error('Opt in with --temporary-keychain-test: creates and deletes one synthetic Keychain item.');
}

const cwd = fileURLToPath(new URL('..', import.meta.url));
const env = { ...process.env, NODE_TLS_REJECT_UNAUTHORIZED: '1' };
const command = (file, args, timeout = 45000) => execFileSync(file, args, {
  cwd, env, timeout, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024, stdio: ['ignore', 'pipe', 'pipe']
});
const directory = mkdtempSync(join(tmpdir(), 'notify-remote-identity-'));
chmodSync(directory, 0o700);
const owner = join(directory, 'owner');
const other = join(directory, 'other');
const updated = join(directory, 'updated');
const publicKey = join(directory, 'public-key.dat');
const id = randomUUID();
const run = (executable, operation) => {
  process.stdout.write(command(executable, [operation, id, publicKey]));
};
const sign = (executable, identifier) => command('codesign', [
  '--force', '--sign', '-', '--identifier', identifier, executable
]);
let attemptedCreation = false;
let cleanupFailed = false;
let failure;
try {
  command('swift', ['build', '--disable-automatic-resolution', '--product', 'NotifyRemoteIdentityChecks'], 180000);
  const bin = command('swift', ['build', '--show-bin-path']).trim();
  copyFileSync(join(bin, 'NotifyRemoteIdentityChecks'), owner);
  sign(owner, 'dev.notify.identity-check');
  copyFileSync(owner, other);
  sign(other, 'dev.notify.identity-check-other');
  command('swift', ['build', '--disable-automatic-resolution', '--product', 'NotifyRemoteIdentityChecks',
    '-Xswiftc', '-DNOTIFY_UPDATED_IDENTITY_CHECK'], 180000);
  copyFileSync(join(bin, 'NotifyRemoteIdentityChecks'), updated);
  sign(updated, 'dev.notify.identity-check');
  for (const executable of [owner, other, updated]) command('codesign', ['--verify', '--strict', executable]);
  run(owner, 'absent');
  attemptedCreation = true;
  run(owner, 'create');
  run(owner, 'load');
  run(other, 'denied');
  run(updated, 'denied');
  run(owner, 'load');
  run(owner, 'corrupt');
  run(owner, 'delete');
  run(owner, 'absent');
} catch (error) {
  failure = error;
} finally {
  if (attemptedCreation) {
    try {
      run(owner, 'cleanup');
      run(owner, 'absent');
    } catch (error) {
      cleanupFailed = true;
      failure = new AggregateError(failure ? [failure, error] : [error],
        `Synthetic Keychain cleanup failed. Preserve owner helper at ${owner}; identity ${id}.`);
    }
  }
  if (!cleanupFailed) {
    for (const path of [owner, other, updated, publicKey]) rmSync(path, { force: true });
    rmdirSync(directory);
  }
}
if (failure) throw failure;
console.log('Remote identity persistence checks passed; temporary item and helpers removed.');
