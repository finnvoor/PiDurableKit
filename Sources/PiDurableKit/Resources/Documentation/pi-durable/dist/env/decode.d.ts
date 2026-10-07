/**
 * Decoding that matches `new TextDecoder().decode(bytes)` of the whole input when the input arrives in pieces. Node's
 * streaming decoder with BOM handling can drop a U+FEFF that follows a chunk boundary, not only a leading byte-order
 * mark, so these decoders turn BOM handling off and drop a leading mark themselves.
 */
/** A streaming decoder for a byte range; callers that start at the beginning of a file skip a leading mark themselves. */
export declare function rangeDecoder(): InstanceType<typeof TextDecoder>;
/** Whether decoding the whole input drops its first three bytes as a byte-order mark. */
export declare function startsWithBom(firstBytes: Uint8Array): boolean;
/** Decodes one stream chunk by chunk exactly like decoding all of it at once. */
export declare class StreamDecoder {
    #private;
    /** Text for `bytes`, holding back an incomplete character; without `bytes`, the end of the stream. */
    decode(bytes?: Uint8Array): string;
}
