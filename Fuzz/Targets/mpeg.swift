@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    _ = MPEG.variable(UnsafeRawBufferPointer(start: data, count: size))
    store(data, size)
    _ = MPEG.variable(url)
    return 0
}
