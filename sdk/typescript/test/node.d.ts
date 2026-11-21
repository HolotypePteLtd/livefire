/**
 * Minimal ambient declarations for the Node built-ins this package's
 * tests use. The runtime is Node >= 22 (global WebSocket, type-stripped
 * TS execution); these keep `tsc --noEmit` honest without a dependency
 * on @types/node, which this unpublished workspace package avoids.
 */

declare module 'node:test' {
  export function test(name: string, fn: () => void | Promise<void>): void;
}

declare module 'node:assert' {
  export function ok(value: unknown, message?: string): void;
  export function equal<T>(actual: unknown, expected: T, message?: string): void;
  export function strictEqual<T>(actual: unknown, expected: T, message?: string): void;
  export function deepStrictEqual<T>(actual: unknown, expected: T, message?: string): void;
  export function match(value: string, test: RegExp, message?: string): void;
  export function notEqual<T>(actual: unknown, expected: T, message?: string): void;
  export function deepEqual<T>(actual: unknown, expected: T, message?: string): void;
  export function rejects(
    fn: () => Promise<unknown>,
    error?: unknown,
  ): Promise<unknown>;
}

declare module 'node:child_process' {
  export interface ChildProcess {
    stdin: { end(): void } | null;
    stdout: NodeJSReadable | null;
    stderr: NodeJSReadable | null;
    once(event: 'exit', cb: (code: number | null) => void): void;
    kill(signal?: string): void;
  }
  export function spawn(
    command: string,
    args: readonly string[],
    options: { cwd?: string; stdio?: readonly string[] },
  ): ChildProcess;
}

declare module 'node:http' {
  export interface IncomingMessage {
    method: string | undefined;
    url: string | undefined;
    headers: Record<string, string | string[] | undefined>;
    on(event: 'data', cb: (chunk: Buffer | string) => void): void;
    on(event: 'end', cb: () => void): void;
  }
  export interface ServerResponse {
    writeHead(status: number, headers?: Record<string, string>): void;
    end(body?: string): void;
  }
  export interface Server {
    listen(port: number, host: string, cb: () => void): void;
    close(cb: () => void): void;
    address(): { port: number } | string | null;
  }
  export function createServer(
    handler: (request: IncomingMessage, response: ServerResponse) => void,
  ): Server;
}

declare module 'node:fs' {
  export function writeFileSync(
    path: string,
    data: string,
    options?: { encoding?: string },
  ): void;
  export function mkdtempSync(prefix: string): string;
  export function rmSync(
    path: string,
    options?: { recursive?: boolean; force?: boolean },
  ): void;
}

declare module 'node:os' {
  export function tmpdir(): string;
}

declare module 'node:crypto' {
  export function createHmac(
    algorithm: string,
    key: Buffer,
  ): {
    update(data: string | Buffer): { digest(encoding: string): string };
  };
  export function randomBytes(size: number): Buffer;
  export function sign(
    algorithm: string,
    data: Uint8Array,
    key: KeyObject,
  ): Buffer;
  export function createPrivateKey(options: {
    key: JsonWebKey;
    format: string;
  }): KeyObject;
  export function generateKeyPairSync(
    algorithm: string,
    options: { namedCurve: string },
  ): { publicKey: KeyObject; privateKey: KeyObject };
  export interface KeyObject {
    export(options: { format: string }): JsonWebKey;
  }
  export const webcrypto: Crypto;
}

declare module 'node:url' {
  export function fileURLToPath(url: string | URL): string;
}

declare module 'node:path' {
  export const dirname: (p: string) => string;
  export const resolve: (...parts: string[]) => string;
  export const join: (...parts: string[]) => string;
}

interface Buffer extends Uint8Array {
  toString(encoding?: string): string;
}

declare const Buffer: {
  from(data: string, encoding: string): Buffer;
  new (data?: unknown): Buffer;
};

interface NodeJSReadable {
  on(event: 'data', cb: (chunk: Buffer | string) => void): void;
  once(event: 'close', cb: () => void): void;
  setEncoding(encoding: string): void;
}
