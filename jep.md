Summary
-------

Metaspace allocator shall return unused memory to the OS more promptly, and make the CPU-to-memory-footprint tradeoff taken by the allocator adjustable.

Non-Goals
---------

- Wholesale replacement of the Metaspace allocator with a different mechanism (e.g. raw malloc, dlmalloc etc).

Success Metrics
---------------

Memory footprint for active Metaspace allocations should go down. Less memory should be retained for released allocations, so Metaspace should behave in a more elastic manner.


Motivation
----------

### Reduce memory footprint and make Metaspace more elastic

Allocating memory for class meta data from Metaspace incurs overhead. That is normal for any allocator. However, overhead-to-payload ratio can get excessive in certain pathological situations.

In particular, two waste areas stick out:

_Intra-chunk waste for active allocations_

When a class loader allocates Metaspace, it gets handed a memory chunk of a larger size than would be necessary to satisfy that single allocation, since it is assumed that the loader will continue loading classes and need more memory for metadata. And if that assumption is correct, giving the loader a memory chunk for exclusive use is a good decision since further allocations can be satisfied concurrently to other allocations from that chunk without bothering the global Metaspace allocator. In addition, the chunk serves as an arena for all allocations from that loader which can be bulk-released when the class loader is unloaded.

But a class loader usually stops class loading at some point. Any memory of that chunk not used up at that point stays unused and is wasted. The VM attempts to deal with that by guessing future loading behavior of a class loader and handing it what it thinks it will need - a loader known or suspected to load only few classes is given a small chunk, a loader assumed to go on loading for a while a big chunk. But that guess can be wrong and currently there is no recurse; the unused remainder of a chunk belonging to a loader which did stop loading classes is wasted.

_Waste in unused chunks_

When a loader gets unloaded, all its chunks are returned to a free list. Those chunks may be reused for future allocation, but that may never happen or at least not in the immediate future. In the meantime that memory is wasted.

Currently that memory is released to the OS when one of the underlying 2MB virtual memory regions happens to only contain free chunks; however that depends highly on fragmentation (how tightly interleaved allocations from live and dead class loaders are). In addition to that, memory in the Compressed Class Space is never returned. So in practice  freelist memory is often retained by the VM.


### Better tunability

A lot of decisions the Metaspace allocator does are trade-offs between speed and memory footprint. This is in particular true for chunk allotment: deciding when a class loader is handed a chunk of which size. Currently those decisions are hard wired and cannot be influenced. It may be advantageous to influence them with an outside switch, e.g. to generally shift emphasis to memory footprint in situations where we care more about footprint than about startup time.  Such a switch would also help with tuning the default allotment policies.

### Code clarity

It is the intention of this proposal that, when implemented, code complexity should ideally go down. Or at least not increase by much. 


Description
-----------

The proposed implementation changes:

### A) Commit in-use chunks lazily and uncommit free chunks

Currently memory is committed in a coarse-grained fashion in the lowest allocation layer, in the nodes of the virtual space list. Each node is a memory mapping - an instance of ReservedSpace with a commit watermark. All chunks carved from that node are completely contained within the committed region.

Proposed change: Let each chunk be responsible for maintaining its own commit watermark, committing its own pages and delay page commits to the point when caller requests memory from the chunk. Furthermore, let chunks which reside in the freelist uncommit their pages.

Notes:
- Obviously, the page containing the chunk header cannot be uncommitted - unless one were to remove the chunk headers from the chunk and store them somewhere else, which is out of scope for this improvement. Only pages followin the header page can be uncommitted. This means only chunks which span multiple pages can uncommit.
- fine granular committing/ucommitting comes with cost: first, runtime costs of the associated mmap calls; then, on the OS layer, fragmentation of the virtual memory into many small segments. So instead of a naive approach where one would uncommit every single page a more controlled and tunable approach is needed where uncommitting would be limited to larger chunks and be done in units of multiple pages. Also, additional logic may be needed to prevent commit/uncommit "flickering" of a single chunk.
 

### B) Replace hard-wired chunk geometry with a buddy-style allocation scheme

Currently there exist three kinds of chunks,  called "specialized", "small" and "medium" for historical reasons, sized (64bit, non-class case) 1K/4K/64K. In addition to that, "humongous" chunks exist of heterogenous sizes larger than a medium chunk. These odd ratios increase fragmentation and footprint unnecessarily:

- increased chunk-internal memory footprint since if a class loader allocates more than 4K we have to give it a full 64K chunk which may be way more than it ever needs.
- increased fragmentation since when chunks are merged upon return to the freelist: to form a 64K chunk we need 16 4K chunks happen to be free at just the right location.

In addition to that, these odd ratios make the metaspace coding difficult to maintain and error-prone. When switching to a by-chunk-commit-scheme, it makes sense to rethink these.

Proposal: Replace the hard-wired three-chunk-type scheme with a buddy-allocation scheme where chunks are sized in power-of-two steps from a minimum size to a maximum size. 

A chunk, when returned to the freelist, will be merged with its buddy (if free), the resulting merged chunk with its buddy (if free) and so forth, until either the largest chunk size is reached or a unfree buddy is encountered. This results in free chunks crystallizing and forming larger chunks. This reduces fragmentation and increased the effect of uncommitting free chunks (fewer and larger ranges to uncommit).

When a chunk would be requested from the freelist, if no free chunk of the requested size is found, a larger chunk will taken and be split. The resulting smaller chunks will be returned to the freelist.

(_Note:_ Partly, this crystallizin-and-splitting happens in the current implementation too, but is hampered by the odd chunk geometry.)

The proposed scheme would also be a prerequisite for parts (B) and (C) of the proposal, see below.

Note that such a change in chunk geometry needs to be coupled with a smarter chunk handout strategy which would be able to reuse free chunks of all sizes. For example, a class loader deemed worthy of large chunks, which normally would have handed a 64K chunk, may be given a 32K or 16K chunk instead if such a chunk happens to be free, before allocating a new 64K chunk from virtual memory.

### B) Reduce intra-chunk waste for active allocations

This could be done with two techniques. Both may be implemented independently from each other.

_B1) Unused chunk space stealing_

With Part (A) in place we may actually split a chunk into smaller ones much more efficiently. That means we could, for all live class loaders, periodically "prune" their current chunks: if a loader used less than half his current chunk, the unused part could be split off and used to form new chunks, which could be returned to the freelist.

Example: A loader stopped loading after using up 12K of a 64K chunk. In that case, we could split that 64K chunk into three chunks sized 16K|16K|32K and return the latter two to the freelist.

The assumption here is that the loader will not continue to load classes, at least not in the immediate future, and therefore the freed chunks will not immediately reallocated by it. A natural point to do this pruning would be when handling a Metaspace OOM. It also could happen independently from OOMs at certain periodic intervals. It could also be combined with a heuristic which tries to guess whether the loader stopped loading classes, e.g. a loader-specific timer.

_B2) Lazily committing chunks_

Currently memory is committed in a coarse-grained fashion in the lowest allocation layer, in the nodes of the virtual space list. Each node is an instance of ReservedSpace with a commit watermark; all allocated chunks are completely contained by the committed region.

This could be changed: For chunks spanning multiple pages, each chunk could maintain its own commit watermark. The first page, containing the chunk header, would be committed from the start; later pages would be committed when the loader allocates memory from the chunk, but not before. The effect would be that intra-chunk waste would be largely prevented for multi-page-sized chunks since unused waste section would remain uncommitted.


### C) Return memory for unused chunks more promptly to the OS

Chunks in the free list are wasted as long as they are not reused, which may be never or not for a long time. Their memory can be uncommitted until they would be reused again. As with (B2), this can only be done for chunks spanning multiple pages, since the header needs to be kept alive. That is why it would benefit from part (A) too, since that would increase the chance of free chunks merging to larger chunks in the free list.

Alternatives
------------

A recurring idea popping up is to get rid of the Metaspace allocator and replace it with a simple malloc() based one. That has obvious drawbacks, since

- we would not be able to allocate contiguous space for Compressed Class Space
- we would be highly dependent on the libc implementation, on various platforms e.g. subject to the process break or being limited by an inconveniently placed Java heap.
- we would potentially be slower and/or increase memory footprint since the malloc allocator is geared toward general purpose, random-free allocations whereas the Metaspace allocator can cut corners knowing e.g. that memory is bulk-freed.

Testing
-------

- TBD -

Risks and Assumptions
---------------------

It is assumed that the consensus is not to re-implement Metaspace in a completely different way. Were that to happen, e.g. a hypothetical switch back to PermGen-in-Java-heap or a re-implementation using platform malloc, this proposal would be moot.

Parts (B2) and (C) assume that committing and uncommitting memory can be done reasonably cheap. If that turns out to be untrue, implementation would have to be adjusted to reduce frequency of commit/uncommit calls, but that would not invalidate the basic idea. 

Dependencies
-----------

- TBD -
