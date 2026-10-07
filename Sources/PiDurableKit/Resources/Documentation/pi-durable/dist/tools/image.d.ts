/** Positional reads of a file of `size` bytes. */
export type ByteSource = {
    readonly size: number;
    read(offset: number, length: number): Promise<Uint8Array>;
};
/**
 * `detectSupportedImageMimeType` of a whole file, reading only its header and, for PNG, the chunk headers up to the
 * first `acTL` or `IDAT`.
 */
export declare function detectSupportedImageMimeTypeOf(source: ByteSource): Promise<string | undefined>;
export declare function detectSupportedImageMimeType(buffer: Uint8Array): string | undefined;
