@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    let lines = LRC.parse(String(decoding: UnsafeBufferPointer(start: data, count: size), as: UTF8.self))
    for position in [-1.0, 0, 30, 1e9] { _ = LRC.index(at: position, in: lines) }
    return 0
}
