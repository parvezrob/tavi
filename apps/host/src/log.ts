// The host's log (#97). A background service's stdout and stderr *are* its
// log — launchd and systemd record them, and `~/.tavi/host.log` keeps both —
// so `info` goes to stdout, `warn` and `error` to stderr, and every line
// carries the same `tavi <level> <component>:` prefix instead of the three
// conventions that had grown up. One call is one line: a value with a
// newline in it (a stack) is escaped rather than wrapped.
//
// The CLI's own voice — `doctor`, `pair`, the update result, the install
// checklist — is output a person asked for, not logging; it stays on plain
// `console.log` in `index.ts`, `pair-command.ts`, `bootstrap-deps.ts` and
// `package-root.ts` (`bootstrap.ts` prints through the injected `report`,
// and `runtime.ts`'s launcher template runs before this module exists).

export type LogFields = Record<string, unknown>;

function format(level: string, component: string, message: string, fields?: LogFields): string {
  const extra = Object.entries(fields ?? {})
    .map(([key, value]) => ` ${key}=${render(value)}`)
    .join("");
  return `tavi ${level} ${component}: ${message}${extra}\n`;
}

function render(value: unknown): string {
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  // An error is worth its stack; quoting keeps the newlines inside the field.
  if (value instanceof Error) return JSON.stringify(value.stack ?? value.message);
  return JSON.stringify(typeof value === "string" ? value : JSON.stringify(value));
}

export const log = {
  info(component: string, message: string, fields?: LogFields): void {
    process.stdout.write(format("info", component, message, fields));
  },
  warn(component: string, message: string, fields?: LogFields): void {
    process.stderr.write(format("warn", component, message, fields));
  },
  error(component: string, message: string, fields?: LogFields): void {
    process.stderr.write(format("error", component, message, fields));
  },
};
