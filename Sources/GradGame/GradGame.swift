@_expose(wasm, "add")
@_cdecl("add")
public func add(_ lhs: Int32, _ rhs: Int32) -> Int32 {
    lhs + rhs
}
