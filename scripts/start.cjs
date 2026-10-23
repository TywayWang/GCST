const { spawn } = require('child_process');
const path = require('path');
const os = require('os');

const isWin = os.platform() === 'win32';
const rootDir = path.resolve(__dirname, '..');
const arg = process.argv[2] || 'All';

const normalizedComponent = (() => {
  const lower = arg.toLowerCase();
  if (lower === 'gc') return 'GC';
  if (lower === 'st') return 'ST';
  return 'All';
})();

if (isWin) {
  const psScript = path.join(rootDir, 'start.ps1');
  const child = spawn('powershell.exe', [
    '-NoProfile',
    '-ExecutionPolicy', 'Bypass',
    '-File', psScript,
    '-Component', normalizedComponent
  ], {
    cwd: rootDir,
    stdio: 'inherit'
  });
  child.on('exit', (code) => process.exit(code || 0));
} else {
  const shScript = path.join(rootDir, 'start.sh');
  const child = spawn('bash', [shScript, normalizedComponent.toLowerCase()], {
    cwd: rootDir,
    stdio: 'inherit'
  });
  child.on('exit', (code) => process.exit(code || 0));
}
