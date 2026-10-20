import Foundation

let path = "/dev/shm/fuzz-\(getpid())"
let url = URL(filePath: path)

func store(_ data: UnsafePointer<UInt8>, _ size: Int) {
    let file = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
    _ = write(file, data, size)
    close(file)
}

func pread(_ file: Int32, _ buffer: UnsafeMutableRawPointer!, _ count: Int, _ offset: Int64) -> Int {
    Glibc.pread(file, buffer, count, Int(offset))
}
