Summary
-------

Promptly return unused Metaspace memory to the Operating System and reduce Metaspace memory footprint.


Goals
-----

- A more elastic Metaspace
- Reduced Metaspace memory footprint
- A cleaner implementation which is cheaper to maintain


Non-Goals
---------

- Getting rid of the class space.
- Changing the way Metaspace is allocated (caller code should not have to change)
- Changing the lifetime of Metaspace objects


Success Metrics
---------------

- Metaspace shall recover from allocation spikes much more readily: we should see a significant reduction in unused-but-committed memory after Metaspace memory is released.

- In scenarios not involving class unloading we should see a small to moderate decrease in committed Metaspace. Under no circumstances should we require more Metaspace.



Motivation
----------

## Preface

Class metadata live in non-java-heap, native memory. Their lifetime is bound to the that of the loading class loader.

At the lowest level, memory is reserved from the OS, piecemeal committed and handed out in chunks of varying sizes to the class loader. From that point on, these chunks are owned by the class loader. From that chunk the class loader does simple pointer bump allocation to serve metadata allocation requests.

If the current chunk is exhausted - its leftover space too small to serve an incoming metadata allocation - a new chunk is handed to the class loader and allocation continues from that new chunk. The current chunk is "retired" - an attempt is made to store the leftover space for later reuse.

When the class loader is unloaded the metaspace it accumulated over its lifetime can be freed: all its chunks are returned to the Metaspace allocator. They are added to a freelist and may be reused for future class loading. It is attempted to return memory to the OS; however, this heavily depends on Metaspace fragmentation and rarely works.


## Goal: make Metaspace more elastic

Allocating memory for class metadata from Metaspace incurs overhead. With the current Metaspace allocator the overhead-to-payload ratio can get excessive.

Two waste areas stick out:

_Waste in free lists_

The size of the free lists can get very excessive. We have seen ratios of up to 70% waste (70% of committed Metaspace memory idling in free lists) after class unloading. Even though there is a mechanism in place to reclaim free metaspace memory and return it to the OS, it is largely ineffective and easily defeated by metaspace fragmentation. Metaspace fragmentation in this case means interleaved placement of chunks from class loaders which have different life spans.

_Intra-chunk waste for active allocations_

Class loaders get assigned a chunk of Metaspace memory; they allocate from it via pointer-bump allocation. Typically, at some point the class loader will stop loading classes and has no further need for Metaspace memory; the remaining space in its current chunk is wasted.

Space wasted this way typically amounts to about 5-12% of committed Metaspace.

A second waste point is leftover space in retired chunks: when the free space left in a chunk is too small to satisfy an allocation, the class loader requests a new chunk; an attempt is made to reuse the leftover space of the old chunk, but often fails. 

Space wasted this way typically amounts to about 1-3% of committed Metaspace.


## Code clarity

Metaspace code has grown over time in complexity; an overhaul would be very beneficial, bringing maintenance costs down and making the code more malleable.


Description
-----------

The proposed implementation changes:

## A) Commit chunks on demand and uncommit free chunks

Currently memory is committed up-front, in a coarse-grained fashion, in the lowest allocation layer. A chunk lives in completely committed memory and remains so for its whole life time, regardless whether it is in use or not.

### Proposal 

Chunks shall be individually committable (also in parts where it makes sense) and uncommittable. Chunks in free lists could be uncommitted and would not count towards the working set size of the VM process.

Chunks in use by a class loader could be committed lazily and in parts. That way large chunks can get handed to class loaders but the full price would not have to be payed up front.

### Commit granules

Where today Metaspace is committed bottom-to-top with a high water mark, in this proposal the Metaspace would become "checkered", consisting of committed and uncommitted ranges. 

A consideration is fragmentation of virtual memory resulting from this. In order to keep virtual memory fragmentation at bay, memory needs to be committed and uncommitted in a sufficiently coarse - and tunable - granularity.

The proposal is to split the Metaspace memory into homogeneous units for the purpose of committing and uncommitting ("commit granules"). A commit granule can only be committed and uncommitted as a whole. The VirtualSpaceNode shall keep track the commit state of the granules it contains. Upper layers can request committing and uncommitting ranges of commit granules.

The size of these commit granules shall be tunable and by default large enough to keep virtual memory fragmentation manageable. 


## B) Replace hard-wired chunk geometry with a buddy allocation scheme

The current chunk allocation scheme knows three kind of chunks, sized 1K/4K/64K respectively, and so-called humongous chunks which are individually sized and larger than 64K. Since JDK-8198423 chunks can be combined and split (e.g. 16 4K chunks can form one 64K chunk). 

The current allocation scheme has a number of disadvantages:

- Ideally, upon returning a chunk to the free list, the chunk should be combined with free neighbors as much as possible to form large contiguous free memory ranges which then could get uncommitted. However, due to the odd chunk geometry, this remains difficult even after JDK-8198423.
- Since there are only three chunk sizes to choose from (disregarding humongous chunks) there is a higher chance of intra-chunk waste. For example, a class loader needing to store a data item of 5K size will require a 64K chunk.
- Chunks have headers, and these headers precede the chunk payload area. They must be present even if the chunk is in a free list. Hence, the page containing the chunk header cannot be uncommitted. This means even if we were to uncommit chunk payload areas, they always would be preceded by a single committed page, increasing virtual memory fragmentation and wasting memory.

### Proposal: 

_Replace the current scheme with a traditional power-2-based buddy allocator._

In this scheme, chunks are sized in power-of-two steps from a minimum size up to a maximum size (these chunk sizes apply to both class and non-class space).

The maximum size shall be large enough to serve any possible Metaspace allocation ("root chunk"). 
The memory range of a VirtualSpaceNode would consist of a series of n root chunks. Its borders would be aligned to root chunk size.

The minimum chunk size shall be small enough to house the majority of InstanceKlass instances in class space (1K for a 64bit VM).

_Remove humongous chunks:_ Since root chunks would be large enough for the largest possible metadata allocation, and chunks can get committed on demand, there is no need for humongous chunks anymore. That significantly simplifies code complexity.

_Split chunk headers from payload:_ they are to be housed in a separate chunk header pool. Separating chunk headers from their chunks would mean the chunks could get fully uncommitted without affecting the headers. Two neighboring uncommitted chunks would then form a single contiguous memory mapping on the OS layer, reducing virtual memory fragmentation.

_Let Chunks grow in place if possible:_ in a power-2 buddy allocation scheme, chunks have a good chance to grow in place if they are too small to house a new Metaspace allocation: if the chunk is followed by an empty buddy chunk, they can be fused to one chunk. 


Advantages:

- Much better defragmentation, also on long runs with many class load/unload cycles. More efficient coalescation of free chunks, allowing for larger contiguous memory ranges. Together with the separation of chunk headers from their payload this is a good preparation for uncommitting larger memory areas while keeping virtual memory fragmentation to a minimum.

- More chunk sizes to choose from would result in less intrachunk waste. The fact that chunks can grow in place is a nice bonus.

- Code clarity: the buddy allocator is a simple standard algorithm which is well known and understood. It is also cheap to implement.

## How allocation works

- A class loader requests n words of Metaspace memory
- The SpaceManager attempts to allocate from its current chunk. 
    - This may lead to committing memory if the allocation spans the boundary of an uncommitted commit granule. 
    - If committing memory fails (hitting limit or GC threshold), allocation fails
- If the chunk is too small to house the allocation, a new chunk is requested from the chunk manager.
    - An attempt is made to grow the chunk in-place.
    - Failing that, an attempt is made to take a new chunk from the free lists.
        - If only a larger chunk is available, it is taken from its free list and split in buddy style fashion to produce the output chunk. The resulting splinter chunks are re-added to the freelist.
    - If no free chunk is found in the free lists, a new root chunk is retrieved from the underlying VirtualSpaceNode. Note that this chunk does not necessarily have to be committed. Again, this chunk is split in buddy style fashion to produce the result chunk, and splinter chunks are added to the free list.

## How bulk-deallocation works
- A class loader is collected, its metadata to be released
    - All chunks owned by this class loader are returned to the global free lists.
    - Chunks are combined in buddy-style fashion with its buddies, producing larger free chunks.
    - Chunks surpassing a certain - tunable - threshold will be uncommitted. Obviously, only chunks equal or larger than a commit granule can be uncommitted.
    - Alternatively, or in combination, when a Metaspace is purged after a GC, free chunks larger than a given threshold can be uncommitted.

## Tunable parameters

- Commit granule size
    - Defaults to 64K
- Whether new root chunks should be fully committed
- To what extend new chunks given to class loaders should be committed
- The threshold beyond which free chunks are to be uncommitted



Alternatives
------------

A recurring idea popping up is to get rid of the Metaspace allocator altogether and replace it with a simple malloc() based one. That has obvious drawbacks, since

- we would not be able to allocate contiguous space for Compressed Class Space
- we would be highly dependent on the libc implementation, on various platforms e.g. subject to the process break or being limited by an inconveniently placed Java heap.
- A custom Metaspace allocator can be specifically geared toward metadata allocation - e.g. use the fact that metadata are bulk-deleted on class loader death.

Testing
-------

A side effect of a new Metaspace implementation should be better testability, which will result in more and better gtests.


Risks and Assumptions
---------------------

It is assumed that the consensus is not to re-implement Metaspace in a completely different way. Were that to happen, e.g. a hypothetical switch back to PermGen-in-Java-heap or a re-implementation using platform malloc, this proposal would be moot.

Dependencies
-----------

- TBD -



[1] https://en.wikipedia.org/wiki/Buddy_memory_allocation


