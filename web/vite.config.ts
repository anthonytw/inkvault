import type { Plugin } from "vite";
import { defineConfig } from "vitest/config";

/**
 * The Content-Security-Policy of the built page (docs/web-viewer.md "Threat
 * model"). Scripts and styles come only from the page's own origin; network
 * requests go only to the page's origin plus the origins listed in
 * SEMPERE_CONNECT_SRC (space-separated, e.g. a WebDAV share on another host);
 * no frames, forms, plugins or <base>; Trusted Types forbid string-to-DOM
 * sinks. Serve the same policy as an HTTP header too (frame-ancestors only
 * works there); the meta tag protects copies served without it.
 */
export function contentSecurityPolicy(connect: string[] = []): string {
  return [
    "default-src 'none'",
    "script-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    `connect-src ${["'self'", ...connect].join(" ")}`,
    "base-uri 'none'",
    "form-action 'none'",
    "object-src 'none'",
    "frame-src 'none'",
    "worker-src 'none'",
    "manifest-src 'none'",
    "require-trusted-types-for 'script'",
    "trusted-types 'none'",
  ].join("; ");
}

function connectOrigins(): string[] {
  const raw = process.env.SEMPERE_CONNECT_SRC ?? "";
  return raw.split(/\s+/).filter((o) => o.length > 0).map((o) => {
    const u = new URL(o);
    if (u.protocol !== "https:" && u.protocol !== "http:") throw new Error(`SEMPERE_CONNECT_SRC: not an http(s) origin: ${o}`);
    return u.origin;
  });
}

function csp(): Plugin {
  return {
    name: "sempere-csp",
    apply: "build",
    transformIndexHtml: {
      order: "post",
      handler: () => [{
        tag: "meta", injectTo: "head-prepend",
        attrs: { "http-equiv": "Content-Security-Policy", content: contentSecurityPolicy(connectOrigins()) },
      }],
    },
  };
}

export default defineConfig({
  base: "./",
  plugins: [csp()],
  build: {
    target: "es2022",
    modulePreload: { polyfill: false },
    sourcemap: false,
    assetsInlineLimit: 0,
  },
  test: {
    environment: "node",
    include: ["test/**/*.test.ts"],
  },
});
