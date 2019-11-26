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
- Changing the life cycle of Metaspace objects


Success Metrics
---------------

- Metaspace shall recover from allocation spikes much more readily: we should see a significant reduction in unused-but-committed memory after Metaspace memory is released.

- In scenarios not involving class unloading we should see a small to moderate decrease in committed Metaspace. Under no circumstances should we require more Metaspace.

Motivation
----------

## Preface

Class metadata live in non-java-heap, native memory. Their lifetime is bound to that of the loading class loader.

At the lowest level, memory is reserved from the OS, piecemeal committed and handed out in chunks of varying (larger) sizes to the class loader. From that point on, these chunks are owned by the class loader. From them the class loader does simple pointer bump allocation to serve metadata allocation requests.

If the current chunk is exhausted - its leftover space too small to serve an incoming metadata allocation - a new chunk is handed to the class loader and allocation continues from that new chunk. The current chunk is "retired" and the leftover space squirreled away for possible later reuse.

When the class loader is unloaded the metaspace it accumulated over its lifetime can be freed: all its chunks are returned to the Metaspace allocator. They are added to a freelist and may be reused for future class loading. It is attempted to return memory to the OS; however, this heavily depends on Metaspace fragmentation and rarely works.


## Goal: make Metaspace more elastic

Allocating memory for class metadata from Metaspace incurs overhead. With the current Metaspace allocator the overhead-to-payload ratio can get excessive.

Two waste areas stick out:

_Waste in free lists_

The size of the free lists can get very excessive. We have seen ratios of up to 70% waste (70% of committed Metaspace memory idling in free lists) after class unloading. Even though there is a mechanism in place to reclaim free metaspace memory and return it to the OS, it is largely ineffective and easily defeated by metaspace fragmentation. Metaspace fragmentation in this case means interleaved placement of chunks from class loaders which have different life spans.

_Intra-chunk waste for active allocations_

Class loaders get assigned a chunk of Metaspace memory; they allocate from it via pointer-bump allocation. Typically, at some point the class loader will stop loading classes and has no further need for Metaspace memory; the remaining space in its current chunk is wasted.

Space wasted this way typically amounts to about 5-20% of committed Metaspace. Note that the more small class loaders exist - loaders only loading few or a single class each - the higher this percentage becomes. Typical examples include loaders for Reflection delegator classes and for hidden classes backing Lambdas. 

A second waste point is leftover space in retired chunks: when the free space left in a chunk is too small to satisfy an allocation, the class loader requests a new chunk; an attempt is made to reuse the leftover space of the old chunk, but often fails. 

Space wasted this way typically amounts to about 1-3% of committed Metaspace.


Description
-----------

We propose the following implementation changes (which are already implemented as a prototype [1]):

## A) Commit chunks on demand and uncommit free chunks

Currently memory is committed up-front, in a coarse-grained fashion, in the lowest allocation layer. A chunk is living in completely committed memory and remains so for its whole life time, regardless whether it is in use or not.

### Proposal 

Chunks shall be individually committable (also in parts where it makes sense) and uncommittable. Chunks in free lists should be uncommitted and would not count towards the working set size of the VM process.

Chunks in use by a class loader could be committed lazily and in parts. That way large chunks can get handed to class loaders but the full price would not have to be paid up front.

### Commit granules

Where today Metaspace is committed bottom-to-top with a high water mark, in this proposal the Metaspace would become "checkered", consisting of committed and uncommitted ranges. 

A consideration is fragmentation of virtual memory resulting from this. In order to keep virtual memory fragmentation at bay, memory needs to be committed and uncommitted in a sufficiently coarse - and tunable - granularity.

This JEP proposes to section the Metaspace memory into homogeneous units for the purpose of committing and uncommitting ("commit granules"). A commit granule can only be committed and uncommitted as a whole. The underlying mapped region shall keep track of the commit state of the granules it contains. Upper layers can request committing and uncommitting ranges of commit granules.

The size of these commit granules shall be tunable and by default large enough to keep virtual memory fragmentation manageable.


## B) Replace hard-wired chunk geometry with a buddy allocation scheme

The current chunk allocation scheme knows three kinds of chunks, sized 1K/4K/64K respectively, and so-called humongous chunks which are individually sized and larger than 64K. Since JDK-8198423 chunks can be combined and split (e.g. 16 4K chunks can form one 64K chunk). 

The current allocation scheme has a number of disadvantages:

- Ideally, upon returning a chunk to the free list, the chunk would be combined with free neighbors as much as possible to form large contiguous free memory ranges which then could get uncommitted. However, due to the odd chunk geometry, this remains difficult even after JDK-8198423.

- Since there are only three chunk sizes to choose from (disregarding humongous chunks) there is a higher chance of intra-chunk waste. For example, a class loader needing to store a data item of 5K size will require a 64K chunk.

- Chunks have headers, and these headers precede the chunk payload area. They must be present even if the chunk is in a free list. Hence, the page containing the chunk header cannot be uncommitted. This means even if we were to uncommit chunk payload areas, they always would be preceded by a single committed page, increasing virtual memory fragmentation and wasting memory.

### Proposal: 

_Replace the current scheme with a power-2-based buddy allocator._

In the buddy allocator scheme, chunks are sized in power-of-two steps from a minimum size up to a maximum size (these chunk sizes apply to both class and non-class space).

The maximum chunk size shall be large enough to serve any possible Metaspace allocation ("root chunk"). The memory range of a VirtualSpaceNode would consist of a series of n root chunks. Its borders would be aligned to root chunk size.

The minimum chunk size shall be small enough to house the majority of InstanceKlass instances in class space (1K for a 64bit VM).

_Remove humongous chunks:_ Since root chunks would be large enough for the largest possible metadata allocation, and chunks can get committed on demand, there is no need for humongous chunks anymore. That significantly reduces code complexity.

_Split chunk headers from payload:_ chunk headers are to be housed in a separate chunk header pool. Separating chunk headers from their chunks would mean chunks could get fully uncommitted without affecting the headers. Two neighboring uncommitted chunks would then form a single contiguous memory mapping on the OS layer, reducing virtual memory fragmentation.

_Let Chunks grow in place if possible:_ in a power-2 buddy allocation scheme, chunks have a good chance to grow in place if they are too small to house a new Metaspace allocation: if the chunk is followed by an empty buddy chunk, they can be fused to one chunk. 

Advantages:

- Much better defragmentation, also in long running VMs with many class load/unload cycles. More efficient coalescation of free chunks, allowing for larger contiguous memory ranges. Together with the separation of chunk headers from their payload this is a good preparation for uncommitting larger memory areas while keeping virtual memory fragmentation to a minimum.

- More chunk sizes to choose from would result in less intrachunk waste. The fact that chunks can grow in place is a nice bonus.

- Code clarity: the buddy allocator is a simple standard algorithm which is well known and understood. This improves maintainability. It is also cheap to implement.


## Example: stepping through memory allocation

Given the new allocation scheme, allocation requires the following steps (leaving out small details like handling of leftover space from retired chunks):

- A class loader requests n words of Metaspace memory. 

- The loader attempts to allocate from its current chunk via pointer-bump. This may lead to committing memory if the allocation spans the boundary of an uncommitted commit granule. If committing memory fails (hitting limit or GC threshold), allocation fails.

- If the chunk is too small to house the allocation, first an attempt is made to grow it in-place by fusing it with its buddy chunk, if that buddy chunk happens to be free.

- Failing that, an attempt is made to take a new chunk from the global free lists.

- If only a larger chunk is available in the global free lists, it is taken from its corresponding list and split in power-of-two-steps to produce the desired output chunk. The resulting splinter chunks are re-added to their corresponding freelist.

- If no free chunk is found in the free lists, a new root chunk is retrieved from the underlying memory region. Note that this chunk does not necessarily have to be committed. Again, this chunk is split in buddy style fashion to produce the result chunk, and any splinter chunks are added to the free list.


## Example: bulk-deallocation

- A class loader is collected, its metadata to be released

- All chunks owned by this class loader are returned to the Metaspace allocator.
    
- For each returned chunk, an attempt is made to fuse it with its buddy chunk, should that be free. That process is repeated until a buddy chunk is encountered which is not free, or until the resulting chunk is a root chunk. The resulting chunk is put into its corresponding free list.
    
- Chunks surpassing a certain - tunable - size threshold will be uncommitted. Obviously, that threshold has to be a multiple of the commit granule size.

- Alternatively, or in combination with the last point, when a Metaspace is purged after a GC, free chunks larger than a given threshold can be uncommitted.


## Memory overhead

Memory overhead of the old implementation and the proposed new one - as implemented in the current prototype - is roughly equivalent and in any case very miniscule compared to the size of the Metaspace itself.

A bitmap per memory region storing the state of commit granules. For a 1 GB Metaspace, this would amount to 2 KB.

The buddy allocator needs to keep state. Two extra fields per chunk header are used for this, increasing chunk header size by 16 bytes. For a typical application allocating about 10000 chunks, this amounts to increase amounts to about 156KB.

We do not need the Occupancy Bitmaps anymore. That reduces memory costs by 128 KB per GB Metaspace.


## Tunable parameters

- Commit granule size
    - Defaults to 64K
- Whether new root chunks should be fully committed
- Initial chunk commit size: to what extend new chunks given to class loaders should be committed
- Uncommit chunk size: size beyond which free chunks are to be uncommitted



Alternatives
------------

A recurring idea popping up is to get rid of the Metaspace allocator altogether and replace it with a simple malloc() based one. A variant of that idea would be to use an existing general purpose allocator (e.g. dlmalloc()) atop of pre-allocated space.

These ideas have the following drawbacks:

1) Using malloc(): we would not be able to allocate contiguous space for Compressed Class Space

2) Using malloc(): we would be very dependent on the libc implementation, e.g. be subject to the process break or being limited by an inconveniently placed Java heap. The same argument goes for any other third-party allocation library we would use.

3) Most importantly, a custom Metaspace allocator can be specifically geared toward Metadata allocation. Since the lifetime of Metadata is scoped to its loading class loader, we can bulk-delete it when the class loader dies and do not have to track every single allocation individually. We can also use the fact that we know the typical allocation sizes (e.g. InstanceKlass allocations will be between 512 bytes and 1 KB) to tailor the Metaspace allocator toward these sizes. Any general purpose allocator has to be efficient over a whole range of allocation sizes. The Metaspace allocator does not.

Testing
-------

A side effect of a new Metaspace implementation would be better isolation of sub components which makes for better testability. This will result in more and better gtests.

Extensive function- and performance tests will be part of this work.

Risks and Assumptions
---------------------

It is assumed that the consensus is not to re-implement Metaspace in a completely different way. Were that to happen, e.g. a hypothetical switch back to PermGen-in-Java-heap or a re-implementation using platform malloc, this proposal would be moot.

Should virtual memory fragmentation become an issue, the uncommit chunk size can be increased or uncommitting switched off completely. We even may monitor metaspace memory fragmentation and automatically tune the uncommit chunk size. With uncommitting shut off the behaviour is roughly comparable to the current implementation. 

Note however that our current prototype shows only a very modest increase in virtual memory fragmentation with the default commit granule size of 64K, so we do not expect this to be a problem.


Dependencies
-----------

- TBD -


[1] See jdk/sandbox repository, "stuefe-new-metaspace-branch": http://hg.openjdk.java.net/jdk/sandbox/shortlog/b537e6386306


