import Foundation
import JavaScriptCore

/// Moves bytes between Swift and JavaScript `Uint8Array`s without per-byte bridging.
enum TypedArray {
    /// The bytes viewed by an integer typed array, or `nil` when `value` is not a typed array.
    static func bytes(of value: JSValue) -> UnsafeMutableRawBufferPointer? {
        guard let context = value.context, value.isObject else { return nil }
        let ref = context.jsGlobalContextRef
        let object = value.jsValueRef
        var exception: JSValueRef?
        let type = JSValueGetTypedArrayType(ref, object, &exception)
        guard exception == nil, type != kJSTypedArrayTypeNone, type != kJSTypedArrayTypeArrayBuffer else { return nil }
        let length = JSObjectGetTypedArrayByteLength(ref, object, &exception)
        guard exception == nil else { return nil }
        guard length > 0 else { return UnsafeMutableRawBufferPointer(start: nil, count: 0) }
        guard let pointer = JSObjectGetTypedArrayBytesPtr(ref, object, &exception), exception == nil else { return nil }
        return UnsafeMutableRawBufferPointer(start: pointer, count: length)
    }

    static func data(of value: JSValue) -> Data? {
        guard let buffer = bytes(of: value) else { return nil }
        guard let base = buffer.baseAddress else { return Data() }
        return Data(bytes: base, count: buffer.count)
    }

    static func makeUint8Array(_ data: Data, in context: JSContext) -> JSValue? {
        let count = data.count
        let pointer = UnsafeMutableRawPointer.allocate(byteCount: max(count, 1), alignment: 1)
        data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: count)
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef,
            kJSTypedArrayTypeUint8Array,
            pointer,
            count,
            { bytes, _ in bytes?.deallocate() },
            nil,
            &exception
        )
        guard exception == nil, let array else {
            pointer.deallocate()
            return nil
        }
        return JSValue(jsValueRef: array, in: context)
    }
}
