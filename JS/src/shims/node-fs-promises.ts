import { native } from "../runtime/native.ts";

export async function mkdir(path: string, _options?: { recursive?: boolean }): Promise<void> {
	native.createDirectory(path);
}
