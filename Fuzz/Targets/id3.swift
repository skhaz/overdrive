@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    store(data, size)
    _ = ID3.read(url)
    _ = Embedded.cover(url)
    return 0
}
