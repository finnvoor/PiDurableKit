# JavaScript Extensions

Install pi-durable extensions written in JavaScript, unchanged.

## Overview

``Extension/init(_:javaScript:sourceURL:)`` evaluates a CommonJS module whose `module.exports` is a pi-durable
extension, and installs it like any other. The module can `require` `@earendil-works/pi-durable` (and its `/tools` and
`/env` entry points), `@earendil-works/pi-ai`, and `@earendil-works/chord/context`.

```js
const { defineExtension, defineTool } = require("@earendil-works/pi-durable");
const { Type } = require("@earendil-works/pi-ai");
module.exports = defineExtension({
  name: "dice",
  tools: [defineTool({
    name: "roll", description: "Roll a die", parameters: Type.Object({ sides: Type.Number() }),
    execute: async (args) => ({ content: [{ type: "text", text: String(1 + Math.floor(Math.random() * args.sides)) }] }),
  })],
});
```

As in pi-durable, extension code is not sandboxed: install only code you trust. To let an agent write extensions, give
it ``PiDurable/documentation``, the bundled pi-durable README and type declarations.
