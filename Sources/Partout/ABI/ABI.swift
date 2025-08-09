import Foundation

@_cdecl("partout_version")
public func partout_version() -> UnsafePointer<CChar> {
    UnsafePointer(strdup("Partout 0.99.x"))
}
