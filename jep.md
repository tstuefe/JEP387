Summary
-------

Metaspace allocator shall return unused memory to the OS more promptly. CPU-to-memory-footprint tradeoff taken by the allocator adjustable.

Non-Goals
---------

Wholesale replacement of the Metaspace allocator with a different mechanism (e.g. raw malloc, dlmalloc etc).


Success Metrics
---------------

Memory footprint for active Metaspace allocations should go down. Less memory should be retained for released allocations, so Metaspace should behave in a more elastic manner.


Motivation
----------

### Reduce memory footprint and make Metaspace more elastic

Allocating memory for class meta data from Metaspace incurs overhead. That is normal for any allocator. However, overhead-to-payload ratio can get excessive in pathological situations.

In particular, two waste areas stick out:

_Intra-chunk waste for active allocations_

When a class loader allocates Metaspace, it gets handed a memory chunk. That chunk is large enough to serve many follow-up allocations of that class loader, since it is assumed that the loader will continue loading classes and use up that chunk. This serves two purposes: for one, it reduces invocations of central - lock-protected - parts of the Metaspace. In addition, by releasing that chunk when the class loader gets unloaded we effectively bulk-release all allocations from that loader; this frees us from the need to track individual allocations.

But a class loader usually stops class loading at some point. From that point on, the still unsused portion of the current chunk is wasted.

_Waste in unused chunks_

When a loader gets unloaded, all its chunks are returned to a free list. Those chunks may be reused for future allocation, but that may never happen or at least not in the immediate future. In the meantime that memory is wasted.

Currently that memory is released to the OS when the underlying VirtualSpaceNode only consists of free chunks; however the chance of that happening depends highly on fragmentation (how tightly interleaved allocations from live and dead class loaders are). To make matters worse, memory in the Compressed Class Space is never returned. So in practice freelist memory is often retained by the VM.


### Better tunability

A lot of decisions the Metaspace allocator does are trade-offs between speed and memory footprint. This is in particular true for chunk allotment: deciding when a class loader is handed a chunk of which size. Many of these decisions are currently hard wired and cannot be influenced easily. 

It may be advantageous to influence them with an outside switch, e.g. to shift emphasis to memory footprint in situations where we care more about footprint than about startup time.

### Code clarity

It is the intention of this proposal that, when implemented, code complexity should go down.


Description
-----------

The proposed implementation changes:

## A) Commit in-use chunks lazily and uncommit free chunks

Currently memory is committed in a coarse-grained fashion in the lowest allocation layer, in the nodes of the virtual space list. Each node is a memory mapping - an instance of ReservedSpace with a commit watermark. All chunks carved from that node are completely contained within the committed region.

Proposed change: Move committing/uncommitting memory to the chunk level. Let each chunk be responsible for maintaining its own commit watermark and commit its own pages. Pages would be committed when a caller requests memory from that chunk - not before. 

Furthermore, let chunks which are put into the freelist uncommit their pages.

The effect this would have is two-fold: for one, the penalty of handing a large chunk to a class loader and it not using the chunk up completely is reduced. Then, when a chunk is returned to the freelist, it can be uncommitted and therefore reduces the memory footprint up to the point where it is needed again.

Notes:

- Obviously, the page containing the chunk header cannot be uncommitted. Only pages following the page containing the chunk header can be uncommitted. This means that this technique can only be used for chunks which span multiple pages.
- committing/ucommitting comes with a cost: first, runtime costs of the associated mmap calls; then, on the OS layer, fragmentation of the virtual memory into many small segments. So we may want to limit committing/uncommitting to a certain granularity and frequency. For example, uncommitting should be limited to larger chunks and be done in batches of n pages. Also, additional logic may be needed to prevent commit/uncommit "flickering" of a single chunk (e.g. caching).
 

## B) Replace hard-wired chunk geometry with a buddy allocation scheme

Currently there exist three kinds of chunks, called "specialized", "small" and "medium" for historical reasons, sized (64bit, non-class case) 1K/4K/64K. In addition to that, "humongous" chunks exist; they are of heterogenous size, larger than a medium chunk. These odd ratios are not the ideal solution.

Since JDK-8198423, we combine free chunks to form larger chunks - meaning, if e.g. a small chunk is returned to the free lists since its class loader died, we attempt to combine it with neighboring free chunks to form a larger chunk. In turn, when a small chunk is needed but only a larger chunk found in the free lists, that chunk is split up into smaller chunks.

However, due to the odd chunk geometry and the existence of humongous chunks that implementation is complicated and not as efficient in preventing fragmentation as it could be. Free lists may still fill up with un-mergeable small chunks which are unsuited if a class loader needs a larger chunk.

Proposal: 

Replace the hard-wired three-chunk-size scheme with a more fluid scheme where chunks are sized in power-of-two steps from a minimum size to a maximum size. This would be very similar to a standard buddy-allocation scheme [1]. Part of the proposal is to get rid of humongous chunks altogether, more about this below.

### Buddy-style chunk merging

Such a buddy-style chunk, when returned to the freelist, would be merged with its buddy (if that is free), the resulting merged chunk with its buddy (if that is free) and so forth, until either the largest chunk size ("root chunk") is reached or an unfree buddy is encountered.

Example: let C1 be a used 4K chunk, c2 a free 4K chunk, c3 a free 8K chunk and C4 a used 16K chunk.

```
0   4   8   12  16  20  24  28  32 k
|   |   |   |   |   |   |   |   |
| C1| c2|   c3  |       C4      |
```

Returning C1 to the freelist will merge it with c2, then in turn with c3. It cannot be merged further since C4 is still in use:

```
0   4   8   12  16  20  24  28  32 k
|   |   |   |   |   |   |   |   |
|       c5      |       C4      |
```

Basically, chunks will "crystallize" around a freed chunk as far as possible.

### Buddy-style chunk merging

When a chunk is requested from the freelist and no chunk of exactly the requested size is found, a larger chunk can  be taken and be split. The resulting superfluous smaller chunks would be returned to the freelist.

Example: 

We have a single 32K free chunk but need a 4K chunk.

```
0   4   8   12  16  20  24  28  32 k
|   |   |   |   |   |   |   |   |
|               c1              |
```

The 32K chunk would be split into, respectively, one 16K, one 8K, and two 4K chunks. All but one of the 4K chunks are returned to the freelist, the one 4K chunk marked as in-use and given to the caller:

```
0   4   8   12  16  20  24  28  32 k
|   |   |   |   |   |   |   |   |
| C2| c3|   c4  |       c5      |
```

##### New Chunk sizes

In the new scheme, the minimum size of a chunk would be 1K (64bit) - large enough to hold 99% of InstanceKlass structures but small enough to not unnecessarily waste memory for class loaders which only ever load one class (e.g. Reflection- or Lambda-CL). This would correspond to the "specialized" chunk of today.

The maximum size of a chunk should be large enough to hold the largest conceivable InstanceKlass structure, plus a healthy margin. I estimate this currently at 4MB. It should be limited upward since the larger this size is, the (slightly) more expensive chunk splitting and merging becomes.

Note that even with this large size - much larger than todays 64K medium chunks, chunk merging and splitting would still be faster: We need 12 operations to form the largest possible chunk (4M) from the smallest possible chunk (1K) whereas today we need 16 operations to form a 64K medium chunk from 16 4K small chunks.

##### We do not need Humongous chunks anymore

Humongous chunks have been a major hindrance in JDK-8198423. Their existence makes the chunk splitting and merging code very complex. I propose to get rid of them since with this proposal they will loose their purpose.

Humongous chunks are currently needed because:

1) sometimes a Metaspace allocation happens to be larger than the largest possible homogenous chunk (medium chunks at 64K). For instance, an InstanceKlass can be larger than 64K if its itable/vtable are large. For those cases, a chunk larger than a medium chunk was needed. And in order to not waste memory, it was made exactly as large as that allocation which caused its creation.

With this proposal, (1) can be achieved differently: when faced with a large Metaspace allocation request (e.g. 65K), one would give it a chunk large enough to fit the data, in this case 128K. Part of this proposal is to commit chunk memory only as needed, not pro-actively, so only the first part of the chunk containing the metadata needs to be committed (in case of the example, on a platform with 4K page size, 68K).

In other words, since the penalty of handing out large chunks to class loaders will be greatly reduced, so we can afford handing out larger chunks to callers which previously would get a hand-crafted humongous chunk.

2) Another reason Humongous chunks exist is that we try to minimize allocations from class loaders which we know will allocate a lot. For example, the bootstrap classloader gets handed humongous chunks in the beginning. That minimizes call backs into the metaspace allocator.

This technique would continue to work with this proposal: one would just give the bootstrap CL a large buddy-style chunk. Again, the delayed-committing of chunks would help to reduce real memory usage.

(Side note, with the advent of CDS most of the humongous chunk allocated for the bootstrap CL remains unused today, so delayed committing would help here.)

##### A new chunk-hand-out strategy toward class loaders

We may want to have a new chunk-allotment strategy, since now, with the new chunk merging mechanism, we can have a multitude of chunks of all (13) sizes in the freelist. 

- TBD -

##### VirtualSpaceNode can be simplified

VirtualSpaceNode coding can be greatly simplified by changing the allocation process a bit: Instead of carving out chunks of all sizes from the node, we only directly carve root chunks (4MB) from the node. Then we pass this root chunk to the freelist, where the next allocation will split it up into the needed chunk sizes.

Also, we take care that VirtualSpaceNode boundaries are aligned to root node size (4MB). 

This simplifies VirtualSpaceNode coding a lot. For instance, we do not need a "retire" mechanism anymore, since there can never be any "leftover chunks": in the current implementation, a node is "retired" when it cannot serve an outstanding metaspace allocation, in which case the leftover space is hacked into smaller chunks and added to the freelist. But with the new scheme, there can be no leftover space since the node is sized to multiples of the largest chunk size, and we only ever allocate in units of the largest chunk size - so we either still have space enogh for a root chunk (which is large enough for every possible allocation) or no space at all.


### General advantages of this proposal:

- the chance to combine free chunks is greatly increased. This reduces fragmentation of free chunks. It makes uncommitting free chunks easier and more effective, since the larger those chunks are the larger the portion which can be uncommitted, and the smaller the number of virtual memory segments created.

- It would reduce fragmentation and thus increase chances to reuse a chunk.

- It would give us more choices as to which chunk sizes to hand to class loaders.

- It would simplify the current implementation by a great deal. For example, the new chunk geometry covers both of the current class- and non-class chunk geometries, so at many places we do not need to distinguish between class- and non-class-space anymore. We can get rid of the OccupancyMap, since it will not be needed anymore. The removal of humongous chunks alone will save a lot of code.


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



[1] https://en.wikipedia.org/wiki/Buddy_memory_allocation

