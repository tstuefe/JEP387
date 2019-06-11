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

When a class loader allocates Metaspace, it gets handed a memory chunk. That chunk is large enough to serve many follow-up allocations of that class loader, since it is assumed that the loader will continue loading classes and use up that chunk. This serves two purposes: for one, it reduces invocations of central - lock-protected - parts of the Metaspace. In addition, by releasing that chunk when the class loader gets unloaded we effectively bulk-release all allocations from that loader without the need to track single allocations.

But a class loader usually stops class loading at some point. At that point, no memory will be allocated from the chunk anymore and therefore the rest of the chunk is wasted. 

The VM attempts to minimize the effect of this by guessing future loading behavior of a class loader and handing it what it thinks it will need - a loader known or suspected to load only few classes is given a small chunk, a loader assumed to go on loading for a while a big chunk. But that guess can be wrong and currently there is no recurse; the unused remainder of a chunk belonging to a loader which did stop loading classes is wasted.

_Waste in unused chunks_

When a loader gets unloaded, all its chunks are returned to a free list. Those chunks may be reused for future allocation, but that may never happen or at least not in the immediate future. In the meantime that memory is wasted.

Currently that memory is released to the OS when one of the underlying 2MB virtual memory regions happens to only contain free chunks; however that depends highly on fragmentation (how tightly interleaved allocations from live and dead class loaders are). In addition to that, memory in the Compressed Class Space is never returned. So in practice freelist memory is often retained by the VM.


### Better tunability

A lot of decisions the Metaspace allocator does are trade-offs between speed and memory footprint. This is in particular true for chunk allotment: deciding when a class loader is handed a chunk of which size. Currently those decisions are hard wired and cannot be influenced. It may be advantageous to influence them with an outside switch, e.g. to generally shift emphasis to memory footprint in situations where we care more about footprint than about startup time.  Such a switch would also help with tuning the default allotment policies.

### Code clarity

It is the intention of this proposal that, when implemented, code complexity should actually go down.


Description
-----------

The proposed implementation changes:

### A) Commit in-use chunks lazily and uncommit free chunks

Currently memory is committed in a coarse-grained fashion in the lowest allocation layer, in the nodes of the virtual space list. Each node is a memory mapping - an instance of ReservedSpace with a commit watermark. All chunks carved from that node are completely contained within the committed region.

Proposed change: Move committing/uncommitting memory to the chunk level. Let each chunk be responsible for maintaining its own commit watermark, commit its own pages. Pages can be committed when a caller requests memory from that chunk - not before. Furthermore, let chunks which reside in the freelist uncommit their pages.

The effect this would have is twofold: for one, the penalty of handing a large chunk to a class loader and it not using the chunk up completely is reduced. Then, when a chunk is returned to the freelist, it can be uncommitted and therefore reduces the memory footprint up to the point where it is needed again.

Notes:

- Obviously, the page containing the chunk header cannot be uncommitted. Only pages followin the header page can be uncommitted. This means only chunks which span multiple pages can uncommit.
- committing/ucommitting comes with cost: first, runtime costs of the associated mmap calls; then, on the OS layer, fragmentation of the virtual memory into many small segments. So we may want to limit committing/uncommitting to a certain granularity and frequency.For example, uncommitting could be limited to larger chunks and be done in batches of multiple pages. Also, additional logic may be needed to prevent commit/uncommit "flickering" of a single chunk.
 

### B) Replace hard-wired chunk geometry with a buddy allocation scheme

Currently there exist three kinds of chunks, called "specialized", "small" and "medium" for historical reasons, sized (64bit, non-class case) 1K/4K/64K. In addition to that, "humongous" chunks exist of heterogenous sizes larger than a medium chunk. These odd ratios are not the ideal solution.

Since JDK-8198423, we combine free chunks to form larger chunks - meaning, if e.g. a small chunk is returned to the free lists since its class loader died, it is attempted to combine it with neighboring free chunks to form a larger chunk. In turn, when a small chunk is needed but only a larger chunk found in the free lists, that chunk is split up into smaller chunks.

However, due to the odd chunk geometry and the existence of humongous chunks the implementation is complicated and the effect may be limited. For example, to form a medium chunk, 16 adjacent small chunks have to happen to be free. So, in times of fragmentation, free lists may fill up with un-mergeable small chunks which are unsuited if a class loader needs a larger chunk.

#### Proposal: 

Replace the hard-wired three-chunk-sizee scheme with a more fluid scheme where chunks are sized in power-of-two steps from a minimum size (1K) to a maximum size (4M). This would be very similar to the standard buddy-allocation scheme [1]. Part of the proposal is to get rid of humongous chunks altogether, more about this below.

##### Buddy-style chunk merging and splitting

A chunk, when returned to the freelist, would be merged with its buddy (if free), the resulting merged chunk with its buddy (if free) and so forth, until either the largest chunk size is reached or a unfree buddy is encountered.

In turn, when a chunk is requested from the freelist and no chunk of the requested size is found, a larger chunk can taken and be split. The resulting superfluous smaller chunks will be returned to the freelist.

##### New Chunk sizes

In the new scheme, the minimum size of a chunk would be 1K (64bit) - large enough to hold 99% of InstanceKlass structures but small enough to not unnecessarily waste memory for class loaders which only ever load one class (e.g. Reflection- or Lambda-CL). This would correspond to the "specialized" chunk of today.

The maximum size of a chunk should be large enough to hold the largest conceivable InstanceKlass structure, plus a healthy margin. I estimate this currently at 4MB. It should be limited upward since the larger this size is, the more expensive chunk splitting and merging becomes. But this would allow us to get rid of humongous chunks.

##### We do not need Humongous chunks anymore

Humongous chunks have been a major hindrance in JDK-8198423. Their existence makes chunk splitting and merging very complicated. I propose to just get rid of them since in this proposal they lost their purpose.

Humongous chunks are currently needed since:

1) sometimes a Metaspace allocation happens to be larger than the largest possible homogenous chunk (medium chunks at 64K). For instance, an InstanceKlass can be larger than 64K if its itable/vtable are large. For those cases, a chunk larger than a medium chunk was needed. And in order to not waste memory, it was made exactly as large as that one allocation which caused its creation.

With this proposal, (1) can be satisfied differently: when faced with a large Metaspace allocation request (e.g. 65K), one would give it a chunk large enought to fit the data, in this case 128K. Part of this proposal is to commit chunk memory only as needed, not pro-actively, so only first part of the chunk containing the metadata needs to be committed (in case of the example, with a 4K page size, 68K).

Described in a different sense, the penalty of handing out large chunks to class loaders is greatly reduced, so we can afford handing out larger chunks to callers (within reason).

2) Another reason Humongous chunks exist is that we try to minimize allocations from class loaders we already know will allocate a lot. For example, the bootstrap classloader gets handed a humongous chunk of 4MB in the beginning. That minimizes call backs into the metaspace allocator.

This technique would continue to work with this proposal: one would just give the bootstrap CL a large buddy chunk. Again, the delayed-committing of chunks would help to reduce real memory usage.

(Side note, with the advent of CDS most of the humongous chunk allocated for the bootstrap CL remains unused today, so delayed committing would help here.)

##### A new chunk-hand-out strategy toward class loaders

- TBD -

##### VirtualSpaceNode can be simplified

Let n be the size of the largest chunk ("a root chunk") possible, 4MB. VirtualSpaceNode should be sized in multiples of this size. When carving out new chunks from a node, only root chunks should be allocated. The root chunk should be added to the freelist and after that, allocation should proceed to happen from the freelist.

This drastically simplifies VirtualSpaceNode coding: We do not need a "retire" mechanism anymore where we add leftover space in a node to the chunk manager. That is because, since a VirtualSpaceNode should be a whole multiple of the largest chunk size, it can never happen that it cannot satisfy a metaspace allocation yet contain left over unused space.



### The advantages of this proposal:

- the chance to combine free chunks is greatly increased. This reduces fragmentation of free chunks. It makes uncommitting free chunks easier and more effective, since the larger those chunks are the larger the portion which can be uncommitted, and the smaller the number of virtual memory segments created.

- It would give us more choices as to which chunk sizes to hand to class loaders.

- It would simplify the current implementation by a great deal. Chunk merging and - splitting would be much simpler.


In addition to that, it is proposed to get rid of the concept of humongous chunks. They are not needed anymore in this scheme. 




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

