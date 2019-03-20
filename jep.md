

Summary
-------

Metaspace allocator shall be improved to reduce memory footprint, return unused memory to the OS more promptly, and make the CPU-to-memory-footprint tradeoff taken by the allocator adjustable.

Non-Goals
---------

- Wholesale replacement of the metaspace allocator with a different mechanism (e.g. raw malloc, dlmalloc etc).

Success Metrics
---------------

Memory footprint for active Metaspace allocations should go down. Less memory should be retained for released Metaspace allocations - Metaspace should be more elastic.


Motivation
----------

### Reduce memory footprint and make Metaspace more elastic

Allocating memory for class meta data from Metaspace incurs overhead. That is normal for any allocator. However, for the JVM, the overhead ratio can get excessive in certain pathological situations.

In particular, two waste areas stick out:

#### Intra-chunk waste for active allocations
When a classloader allocates metaspace, it gets handed a memory chunk of a (often much) larger size than would be necessary to satisfy that single allocation. It is guessed that the loader will continue loading classes and store metadata. And if that guess is correct, giving the loader a memory chunk for exlusive use is a good decision since further allocations can be satisfied concurrently to other allocations, lock-free, from that chunk without bothering the global Metaspace allocator. In addition, the chunk serves as an arena for all allocations from that class loader, simplifying bulk-releasing that memory when the class loader goes away.

But a class loader usually stops and never resumes class loading at some point. Any memory of that chunk not used up at that point stays unused and is wasted. That is why it is important to correctly guess future loading behaviour for a class loader; e.g. loaders known or suspected to load only few classes are given very small chunks. But in the end, that guess can go wrong; currently there is no mechanism to reuse the rest of unused chunks for different loaders.

#### Waste in unused chunks

When a loader gets unloaded, all its chunks are returned to a free list. Those chunks may be reused for future allocation, but that may never happen or at least not in the immediate future. In the meantime that memory is wasted.

Currently that memory is released to the OS when one of the underlying 2MB virtual memory regions happens to only contain free chunks; however that depends highly on fragmentation (how tightly interleaved allocations from live and dead classloaders are). In addition to that, memory in the Compressed Class Space is never returned. So in practice much of freelist Metaspace memory is often retained by the VM.

### Better tunability

A lot of decisions the Metaspace allocator does are tradeoffs between speed and memory footprint. This is in particular true for chunk allotment: deciding when a class loader is handed a chunk of which size. Currently those decisions are hard wired and cannot be influenced. It may be advantagous to influence them with an outside switch, e.g. to generally shift emphasis to memory footprint in situations where we care more about footprint than about startup time. That would make it also interesting to experiment with different settings.

### Code clarity

It is the intention of this proposal that, when implemented, code complexity should ideally go down. Or at least not increase by much. 


Description
-----------

The proposed implementation changes come in three parts:

### A) Replace hard-wired chunk geometry with a buddy-style allocation scheme

Currently there exist three kinds of chunks - leaving out humongous chunks for sake of simplicity - called "specialized", "small" and "medium" for historic reason. They are typically sized 1K/4K/64K. These odd ratios increase fragmentation and sometimes footprint unnecessarily and hamper in a number of ways. 

- It may increase memory footprint since if a class loader allocates more than 4K we have to give it a full 64K chunk which may be way more than it ever needs.
- It increases fragmentation unnecessarily since when chunks are merged upon return to the freelist, to form a 64K chunk we need 16 4K chunks happen to be free at just the right location.

It is proposed to replace the hard-wired three-chunk-type scheme with a more fluent one where chunks are sized in power-of-two steps from a minimum (1K) to a maximum (64K) - essentially a buddy-allocation scheme. Chunks would have to be allocated at boundaries aligned to their chunk size, but that is already the case today (since the introduction of chunk coalescation).

The proposed scheme would also the the prerequisite for parts (B) and (C) of the proposal, see below.

Note that such a change in chunk geometry needs to be coupled with a smarter chunk handout strategy which would be able to reuse free chunks of all sizes. For example, a class loader deemed worthy of large chunks, which normally would have handed a 64K chunk, may be given a 32K or 16K chunk instead if such a chunk happens to be free, before allocating a new 64K chunk from virtual memory.

### B) Reduce intra-chunk waste for active allocations

This could be done with two techniques. Both may be implemented independently from each other.

#### B1) Unused chunk space stealing

With Part (A) in place we may actually split a chunk into smaller ones much more efficiently. That means we could, for all live class loaders, periodically "prune" their current chunks: if a loader used less than half his current chunk, the unused part could be split off and used to form new chunks, which could be returned to the freelist.

Example: A loader stopped loading after using up 12K of a 64K chunk. In that case, we could split that 64K chunk into three chunks sized 16K|16K|32K and return the latter two to the freelist.

The assumption here is that the loader will not continue to load classes, at least not in the immediate future, and therefore the freed chunks will not immediately reallocated by it. A natural point to do this pruning would be when handling a Metaspace OOM. It also could happen independently from OOMs at certain periodic intervals. It could also be combined with a heuristic which tries to guess whether the loader stopped loading classes, e.g. a loader-specific timer.

#### B2) Lazily committing chunks

Currently memory is committed in a coarse-grained fashion in the lowest allocation layer, in VirtualSpaceNode. Each node is a ReservedSpace with a commit watermark; all allocated chunks are completely contained by the committed region.

This could be changed: For chunks spanning multiple pages, each chunk could maintain its own commit watermark. The first page, containing the chunk header, would be committed from the start; later pages would be committed when the loader allocates memory from the chunk, but not before.

### C) Return memory for unused chunks more promptly to the OS

Chunks in the free list are wasted as long as they are not reused, which may be never or not for a long time. Their memory can be uncommitted until they would be reused again. As with (B2), this can only be done for chunks spanning multiple pages, since the header needs to be kept alive. That is why it would benefit from part (A) too, since that would increase the chance of free chunks merging to larger chunks in the free list.


Alternatives
------------

A recurring idea popping up is to get rid of the Metaspace allocator and replace it with a simple malloc() based one. That has obvious drawbacks, since
- we would not be able to allocate contiguous space for Compressed Class Space
- we would be highly dependend on the libc implementation, on various platforms e.g. subject to the process break or being limited by an inconveniently placed Java heap.
- we would potentially be slower and/or increase memory footprint since the malloc allocator is geared toward general purpose, random-free allocations whereas the Metaspace allocators can cut corners knowing e.g. that memory is bulk-freed.

Testing
-------

- TBD -

Risks and Assumptions
---------------------

It is assumed that the consensus is not to re-implement Metaspace in a completely different way. Were that to happen, e.g. a hypothetical switch back to PermGen-in-Java-heap or a re-implementation using platform malloc, this proposal would be moot.

It is also assumed that scenarios which load and unload many class loaders keep being valid and important. A general switch to microservice-everything with tiny heaps and a single app class loader never unloading would make this proposal unnecessary.

Parts (B2) and (C) assume that committing and uncommitting memory can be done reasonably cheap. If that turns out to be untrue, implementation would have to be adjusted to reduce frequency of commit/uncommit calls, but that would not invalidate the basic idea. 

Dependencies
-----------

- TBD -

(This is a draft for a possible future JEP improving the metaspace allocator)
