// Supervise the two foreground services. Unexpected failure of either exits the
// container so the engine/systemd can restart it. Engine init reaps descendants.
import { spawn } from 'node:child_process';

const [command, ...args] = process.argv.slice(2);
const children = new Set();
let stopping = false;
let exitCode = 0;
let deadline;

function stop(code) {
  if (stopping) return;
  stopping = true;
  exitCode = code;
  for (const child of children) child.kill('SIGTERM');
  deadline = setTimeout(() => {
    for (const child of children) child.kill('SIGKILL');
  }, 15_000);
  deadline.unref();
  if (!children.size) process.exit(exitCode);
}

function start(program, argv, options = {}) {
  const child = spawn(program, argv, { stdio: 'inherit', ...options });
  children.add(child);
  child.on('error', (error) => {
    console.error(`lucoa: could not start ${program}: ${error.message}`);
    stop(1);
  });
  child.on('close', () => {
    children.delete(child);
    if (!stopping) {
      console.error(`lucoa: ${program} exited unexpectedly; stopping container`);
      stop(1);
    }
    if (!children.size) {
      clearTimeout(deadline);
      process.exit(exitCode);
    }
  });
}

process.on('SIGTERM', () => stop(0));
process.on('SIGINT', () => stop(0));
// Disable passwords, root login, and forwarding. hc uses SSH command/stdio.
// Do not use -e: authenticated shells must not inherit service secrets.
start('dropbear', ['-F', '-E', '-m', '-s', '-w', '-j', '-k',
  '-p', '0.0.0.0:2222', '-P', `${process.env.XDG_RUNTIME_DIR}/dropbear.pid`,
  '-r', `${process.env.HOME}/.ssh/dropbear_ed25519_host_key`]);
start(command, args);
