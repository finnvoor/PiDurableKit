// The JavaScript half of PiDurableKit: a bridge from Swift to pi-durable. See core.ts for the protocol.
import "../runtime/index.ts";
import "./core.ts";
import "./models.ts";
import "./tx.ts";
import "./scopes.ts";
import "./extensions.ts";
import "./harness.ts";
import { register } from "./core.ts";
import { VERSIONS } from "../versions.ts";

register({ versions: () => VERSIONS });
