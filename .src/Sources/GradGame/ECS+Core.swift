// ECS+Core.swift
// ──────────────────────────────────────────────────────────────────────────
// Textbook Entity-Component-System *surface* — Entity handles, Component value
// structs — backed by concrete per-archetype struct-of-arrays in `World`
// (ECS+World.swift) and operated on by free `*System` functions (ECS+Systems.swift).
//
// DELIBERATELY NOT a generic/reflective ECS. The swift-6.3.2-RELEASE_wasm SDK
// hard-traps (an `unreachable` the host `swift test` can't catch) on exactly the
// machinery a literal ECS uses — populated `Dictionary` (type-keyed component
// stores), variadic generics (`query<each C>`), existentials (`[any Component]`),
// metatype lookups, and generic `Array` higher-order methods. So storage is plain
// `[Double]`/`[Int]`/`[Bool]` columns, queries are index walks, and `Component`
// below is a compile-time marker only. Do NOT "modernise" this into a generic
// registry — it will freeze the wasm input box. See swiftwasm-trapping-patterns.
// ──────────────────────────────────────────────────────────────────────────

/// Opaque entity handle. `id` is the row index into the archetype columns the
/// entity was spawned into (cannons: id == seat). `Equatable` is synthesised to
/// compare a single `Int` — no `Hashable`, no `Set`, no dictionary keying, so it
/// never touches the metatype/hashing machinery that traps on wasm.
struct Entity: Equatable {
    var id: Int
}

/// Compile-time / documentation marker ONLY. Never used as `[any Component]`,
/// never queried by type at runtime, never a dictionary key — conforming a value
/// struct to it costs nothing on wasm.
protocol Component {}

// ── Spatial / cannon-archetype components ──────────────────────────────────────
struct Position: Component { var x: Double; var y: Double }
struct Alive: Component { var value: Bool }
struct Shape: Component { var radius: Double }
struct Seat: Component { var index: Int }

// ── Shot-archetype components (the shot is itself an Entity) ───────────────────
/// outcome: 0 = out, 1 = hit, 2 = blocked. (-1 is the FFI "no shot" sentinel.)
struct Outcome: Component { var value: Int }
/// Impact point + which seat was hit (-1 if none). NaN x/y when no points produced.
struct Impact: Component { var x: Double; var y: Double; var seat: Int }
/// Flat polyline [x0,y0,x1,y1,…]. A single `[Double]` (never `[[Double]]`) so it
/// stays inside the wasm-safe array subset (append/count/subscript/withUnsafe…).
struct Trajectory: Component { var points: [Double] }
