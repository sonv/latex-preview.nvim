// Shared line-protocol client for daemon regression tests and benchmarks.
import { spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";

export const defaultDaemon = fileURLToPath(new URL("../scripts/mathjax-daemon.mjs", import.meta.url));

export async function startDaemon(script = defaultDaemon) {
  const child = spawn(process.execPath, [script, "--daemon"], { stdio: ["pipe", "pipe", "pipe"] });
  const lines = createInterface({ input: child.stdout });
  const pending = [];
  let errors = "";
  let nextId = 1;
  let failure;
  child.stderr.on("data", (data) => { errors += data; });
  const fail = (error) => {
    failure = error;
    for (const waiter of pending.splice(0)) waiter.reject(error);
  };
  child.on("error", fail);
  child.on("exit", (code, signal) => fail(new Error(`daemon exited (${code ?? signal}): ${errors}`)));
  lines.on("line", (line) => {
    const waiter = pending.shift();
    if (!waiter) return fail(new Error(`unexpected daemon response: ${line}`));
    try { waiter.resolve(JSON.parse(line)); } catch (error) { waiter.reject(error); }
  });
  const response = () => new Promise((resolve, reject) => {
    if (failure) return reject(failure);
    const timer = setTimeout(() => {
      child.kill();
      reject(new Error(`daemon response timed out: ${errors}`));
    }, 30000);
    pending.push({
      resolve: (value) => { clearTimeout(timer); resolve(value); },
      reject: (error) => { clearTimeout(timer); reject(error); },
    });
  });
  const ready = await response();
  if (!ready.ready) throw new Error(`expected ready response: ${JSON.stringify(ready)}`);
  return {
    request(request) {
      const result = response();
      child.stdin.write(JSON.stringify({ id: nextId++, ...request }) + "\n");
      return result;
    },
    raw(line) {
      const result = response();
      child.stdin.write(line + "\n");
      return result;
    },
    close() {
      child.stdin.end();
      child.kill();
      lines.close();
    },
  };
}
