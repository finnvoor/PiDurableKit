// Web platform for JavaScriptCore. Import order matters: later modules use earlier globals.
import "./native.ts";
import "./globals.ts";
import "./events.ts";
import "./encoding.ts";
import "./blob.ts";
import "web-streams-polyfill/polyfill";
// ECMAScript built-ins newer than the oldest supported JavaScriptCore, plus URL, structuredClone, atob/btoa.
import "core-js/actual";
import "./fetch.ts";
