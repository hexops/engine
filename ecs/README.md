# mach/ecs, an Entity Component System for Zig <a href="https://hexops.com"><img align="right" alt="Hexops logo" src="https://raw.githubusercontent.com/hexops/media/master/readme.svg"></img></a>

`mach/ecs` is an Entity Component System for Zig built from first-principles.

## Design principles:

* Clean-room implementation (author has not read any other ECS implementation code.)
* Solve the problems ECS solves, in a way that is natural to Zig and leverages Zig comptime.
* Avoid patent infringement upon Unity ECS patent claims.
* Fast. Optimal for CPU caches, multi-threaded, leverage comptime as much as is reasonable.
* Simple. Small API footprint, should be natural and fun - not like you're writing boilerplate.
* Enable other libraries to provide tracing, editors, visualizers, profilers, etc.

## ⚠️ in-development ⚠️

Under heavy development, not ready for use!

As development continues, we're publishing a blog series ["Let's build an Entity Component System from scatch"](https://devlog.hexops.com/categories/lets-build-an-ecs).

Join us in developing it, give us advice, etc. [on Matrix chat](https://matrix.to/#/#ecs:matrix.org) or [follow updates on Twitter](https://twitter.com/machengine).

## Known issues

There are plenty of known issues, and things that just aren't implemented yet. And certainly many unknown issues, too.

* Missing multi-threading!
* Currently only handles entity management, no world management or scheduling. No global data, etc.
* Lack of API documentation (see "example" test)
* Missing hooks that would enable visualizing memory usage, # of entities, components, etc. and otherwise enable integration of editors/visualizers/profilers/etc.
* We have dense and sparse data, but no shared data yet.
* If many entities are deleted, iteration becomes slower due to needing to skip over entities in the free_slots set, we should add a .compact() method that allows for remediating this.
* If *tons* of entities are deleted, even with .compact(), memory would not be free'd / returned to the OS by the underlying components arrays. We could add a .compactAndFree() method to correct this.
* It would be nicer if there were configuration options for performing .compactAndFree() automatically, e.g. if the number of free entity slots is particularly high or something.
* Currently we do not expose an API for pre-allocating entities (i.e. allocating capacity up front) but that's very important for perf and memory usage in the real world.
* When entity is deleted, maybe via systems / an event/callback, need a way to be notified of destruction. Same with updated maybe.

See also the numerous TODOs in main.zig.

## Copyright & patent mitigation

The initial implementation was a clean-room implementation by Stephen Gutekanst without having read other ECS implementations' code, but with speaking to people familiar with other ECS implementations. Contributions past the initial implementation may be made by individuals in non-clean-room settings (familiar with open source implementations only.)

Critically, this entity component system stores components for a classified archetype using independent arrays allocated per component as well as hashmaps for sparse component data as an optimization. This is a novel and fundamentally different process than what is described in Unity Software Inc's patent US 10,599,560. This is not legal advice.
