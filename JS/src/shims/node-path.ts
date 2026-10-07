export function dirname(path: string): string {
	const trimmed = path.replace(/\/+$/, "");
	const index = trimmed.lastIndexOf("/");
	if (index < 0) return ".";
	if (index === 0) return "/";
	return trimmed.slice(0, index);
}
