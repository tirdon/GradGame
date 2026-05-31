#if canImport(Darwin)
import Darwin
#elseif canImport(WASILibc)
import WASILibc
#elseif canImport(Glibc)
import Glibc
#endif

// ── firebaseConfig (kept out of the HTML source; read from the binary at boot) ──

private let firebaseConfigJSON = """
{"apiKey":"AIzaSyBwl5fs3MEQh5_AIWVsc9rzfOUH70ypncw","authDomain":"webdata-26edf.firebaseapp.com","databaseURL":"https://webdata-26edf-default-rtdb.asia-southeast1.firebasedatabase.app","projectId":"webdata-26edf","storageBucket":"webdata-26edf.firebasestorage.app","messagingSenderId":"411882405034","appId":"1:411882405034:web:5e98982af98fb49ca024d3"}
"""

private nonisolated(unsafe) var firebaseConfigPointer: UnsafeMutableRawPointer?
private nonisolated(unsafe) var firebaseConfigByteCount: Int32 = 0

@_expose(wasm, "gradGameFirebaseConfig")
@_cdecl("gradGameFirebaseConfig")
public func gradGameFirebaseConfig() -> UnsafePointer<UInt8>? {
    if let firebaseConfigPointer {
        return UnsafePointer(firebaseConfigPointer.assumingMemoryBound(to: UInt8.self))
    }
    let bytes = Array(firebaseConfigJSON.utf8)
    firebaseConfigByteCount = Int32(bytes.count)
    guard !bytes.isEmpty else { return nil }
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: bytes.count, alignment: 1)
    bytes.withUnsafeBytes { source in
        if let baseAddress = source.baseAddress {
            pointer.copyMemory(from: baseAddress, byteCount: bytes.count)
        }
    }
    firebaseConfigPointer = pointer
    return UnsafePointer(pointer.assumingMemoryBound(to: UInt8.self))
}

@_expose(wasm, "gradGameFirebaseConfigLength")
@_cdecl("gradGameFirebaseConfigLength")
public func gradGameFirebaseConfigLength() -> Int32 {
    firebaseConfigByteCount
}
