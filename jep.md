Summary
-------

Promptly return unused Metaspace memory to the operating system and reduce Metaspace memory footprint.


Goals
-----

- A more elastic Metaspace. It should recover from usage spikes much more readily, returning memory to the operating system after class unloading.
- Reduced Metaspace memory footprint
- A cleaner implementation which is less difficult to maintain


Non-Goals
---------

This proposal does not touch the way compressed class pointer encoding works or the way the compressed class space is implemented.



Motivation
----------

### Preface

Class metadata live in non-java-heap, native memory. Their lifetime is bound to that of the loading class loader.

At the lowest level, memory is reserved from the OS, committed as needed, and handed out in chunks of varying (larger) sizes to the class loader. From that point on, these chunks are owned by the class loader.  The class loader does simple pointer bump allocation to serve metadata allocation requests from these chunks.

If the current chunk is exhausted - its leftover space too small to serve an incoming metadata allocation - a new chunk is handed to the class loader and allocation continues from that new chunk. The current chunk is "retired" and the leftover space squirreled away for possible later reuse.

When the class loader is unloaded the Metaspace memory it accumulated over its lifetime can be freed: all its chunks are returned to the Metaspace allocator. They are added to a freelist and may be reused for future class loading.  The Metaspace allocator attempts to return memory to the OS; however, this heavily depends on Metaspace fragmentation and rarely works.


### Goal: Make Metaspace more elastic

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

We propose the following implementation changes (which are already implemented as a prototype [\[1\](#footnote1)):

### A) Commit chunks on demand and uncommit free chunks

Currently memory is committed up-front, in a coarse-grained fashion, in the lowest allocation layer. A chunk is living in completely committed memory and remains so for its whole life time, regardless whether it is in use or not.

#### Proposal 

Chunks shall be individually committable and uncommittable. Chunks in free lists should be uncommitted where it makes sense and thus would not count towards the working set size of the VM process.

Larger chunks should not be committed as a whole but only on demand, similar to thread stacks. That way larger chunks can get handed to class loaders but the full price would not have to be paid up front.

#### Commit granules

Where today Metaspace is committed bottom-to-top with a high water mark, in this proposal the Metaspace would become "checkered", consisting of committed and uncommitted ranges. 

In order to keep virtual memory fragmentation at bay, memory needs to be committed and uncommitted in a sufficiently coarse - and tunable - granularity.

This JEP proposes to section the Metaspace memory into homogeneous units for the purpose of committing and uncommitting ("commit granules"). A commit granule can only be committed and uncommitted as a whole. The underlying mapped region shall keep track of the commit state of the granules it contains. Upper layers can request committing and uncommitting ranges of commit granules.

The size of these commit granules shall be tunable and by default large enough to keep virtual memory fragmentation manageable.


### B) Replace hard-wired chunk geometry with a buddy allocation scheme

The current chunk allocation scheme knows three kinds of chunks, sized 1K/4K/64K respectively, and so-called humongous chunks which are individually sized and larger than 64K. Since JDK-8198423 chunks can be combined and split (e.g. 16 4K chunks can form one 64K chunk). 

The current allocation scheme has a number of disadvantages:

- Ideally, upon returning a chunk to the free list, the chunk would be combined with free neighbors as much as possible to form large contiguous free memory ranges which then could get uncommitted. However, due to the odd chunk geometry, this remains difficult even after JDK-8198423.

- Since there are only three chunk sizes to choose from (disregarding humongous chunks) there is a higher chance of intra-chunk waste. For example, a class loader needing to store a data item of size 5K will require a 64K chunk.

- Chunks have headers, and these headers precede the chunk payload area. They must be present even if the chunk is in a free list. Hence, the page containing the chunk header cannot be uncommitted. This means even if we were to uncommit chunk payload areas, they always would be preceded by a single committed page, increasing virtual memory fragmentation and wasting memory.

- Humongous chunks, currently needed to handle large singular Metadata allocations, always need special treatment.

#### Proposal: 

_Replace the current scheme with a power-2-based buddy allocator._

In the buddy allocator scheme, chunks are sized in power-of-two steps from a minimum size up to a maximum size (these chunk sizes apply to both class and non-class space).

The maximum chunk size shall be large enough to serve any possible Metaspace allocation ("root chunk"). The memory range of a VirtualSpaceNode would consist of a series of n root chunks. Its borders would be aligned to root chunk size.

The minimum chunk size shall be small enough to house the majority of InstanceKlass instances in class space (1K for a 64bit VM).

_Remove humongous chunks:_ Since root chunks would be large enough for the largest possible metadata allocation, and chunks can get committed on demand, there is no need for humongous chunks anymore. That significantly reduces code complexity.

_Split chunk headers from payload:_ chunk headers are to be housed in a separate chunk header pool. Separating chunk headers from their chunks would mean chunks could get fully uncommitted without affecting the headers. Two neighboring uncommitted chunks would then form a single contiguous memory mapping on the OS layer, reducing virtual memory fragmentation.

_Let Chunks grow in place if possible:_ in a power-2 buddy allocation scheme, chunks have a good chance to grow in place if they are too small to house a new Metaspace allocation: if the chunk is followed by an empty buddy chunk, they can be fused to one chunk. 

Advantages:

- Much better defragmentation, also in long running VMs with many class load/unload cycles. More efficient coalescation of free chunks, allowing for larger contiguous memory ranges. Together with the separation of chunk headers from their payload this allows for uncommitting larger memory areas while keeping virtual memory fragmentation to a minimum.

- More chunk sizes to choose from would result in less intra-chunk waste. The fact that chunks can grow in place is a nice bonus.

- Code clarity: the buddy allocator is a simple standard algorithm which is well known and understood. This improves maintainability. It is also cheap to implement.


### Example: stepping through memory allocation

Given the new allocation scheme, allocation requires the following steps (leaving out small details like handling of leftover space from retired chunks):

- A class loader requests n words of Metaspace memory. 

- The loader attempts to allocate from its current chunk via pointer-bump. This may lead to committing memory if the allocation spans the boundary of an uncommitted commit granule. If committing memory fails (hitting limit or GC threshold), allocation fails.

- If the chunk is too small to house the allocation, first an attempt is made to grow it in-place by fusing it with its buddy chunk, if that buddy chunk happens to be free.

- Failing that, an attempt is made to take a new chunk from the global free lists.

- If only a larger chunk is available in the global free lists, it is taken from its corresponding list and split in power-of-two-steps to produce the desired output chunk. The resulting splinter chunks are re-added to their corresponding freelist.

- If no free chunk is found in the free lists, a new root chunk is retrieved from the underlying memory region. Note that this chunk does not necessarily have to be committed. Again, this chunk is split in buddy style fashion to produce the result chunk, and any splinter chunks are added to the free list.

- The result chunk is given to the requesting class loader.

- Prior to use, the first (n, adjustable) commit granules of the chunk are committed. The originally requested n words of memory are allocated from the top of the chunk and returned.

- In subsequent allocations, more words will be taken from the chunk. Further granules will be committed as needed. This continues until the chunk is used up, when the cycle repeats with a new chunk.


### Example: bulk-deallocation

- A class loader is collected, its metadata to be released

- All chunks owned by this class loader are returned to the Metaspace allocator.
    
- For each returned chunk, an attempt is made to fuse it with its buddy chunk, should that be free. That process is repeated until a buddy chunk is encountered which is not free, or until the resulting chunk is a root chunk. The resulting chunk is put into its corresponding free list.
    
- Chunks surpassing a certain - tunable - size threshold will be uncommitted. Obviously, that threshold has to be a multiple of the commit granule size.

- Alternatively, or in combination with the last point, when a Metaspace is purged after a GC, free chunks larger than a given threshold can be uncommitted.


### Memory overhead

Memory overhead of the old implementation and the proposed new one - as implemented in the current prototype - is roughly equivalent and in any case very minuscule compared to the size of the Metaspace itself.

A bitmap per memory region storing the state of commit granules. For a 1 GB Metaspace, this would amount to 2 KB.

The buddy allocator needs to keep state. Two extra fields per chunk header are used for this, increasing chunk header size by 16 bytes. For a typical application allocating about 10000 chunks, this amounts to increase amounts to about 156KB.

We do not need the Occupancy Bitmaps anymore. That reduces memory costs by 128 KB per GB Metaspace.


### Tunable parameters

There are many ways to fine-tune the behavior of the Metaspace allocator, the most important being:

- Commit granule size: a coarser size would reduce the beneficial effects of uncommitting memory but decrease the virtual memory fragmentation at the OS layer.
- Whether chunks handed to class loaders should be fully committed, partly committed or left uncommitted. Fully committing chunks at that stage disables the committing-on-demand feature; it will save some calls into the Metaspace allocator later on at the cost of using more memory. In practice, that effect has been shown to be not measurable however and a good practice seems to be to just commit the first granule of a chunk and leave subsequent areas uncommitted.

In practice, it was found that fine tuning all these parameters independently from each other was unnecessary, so just one new switch was introduced to set behavior to reasonable defaults:

`-XX:MetaspaceReclaimStrategy=(none|balanced|aggressive)`, with `balanced` being the default.

- `balanced` aims to give the best compromise between memory reclamation and overhead.
- `aggressive` reclaims more memory a the cost of more fragmentation at the virtual memory area layer.
- `none` is a fallback setting disabling memory reclamation altogether. No overhead is being paid but no memory is being reclaimed apart from unmapping completely evacuated virtual space regions. In practice, this setting reinstates the behavior Metaspace currently has.


### Backward compatibility

#### Memory usage, MaxMetaspaceSize and CompressedClassSpaceSize

We will be backward compatible in terms of memory usage. The VM should not use more committed memory than it did before. Existing installations which manually limit Metaspace size using `-XX:MaxMetaspaceSize=xxx` should not be disturbed, e.g. suddenly receive OOMs, as a result of this work.

The proposed buddy allocator imposes a granularity to the reserved size of Metaspace. This will affect the reservation of class space such that its size can only be a multiple of a commit granule size, which is currently designed to be 4M. This means that if the class space size is specified via `-XX:CompressedClassSpaceSize=xxx`, the effective size of class space will be rounded up to the next 4M boundary. This may very slightly increase the reserved size of class space. This does not affect the size of committed memory.

#### InitialBootClassLoaderMetaspaceSize

The option `InitialBootClassLoaderMetaspaceSize` is not needed anymore and we can get rid of it to reduce complexity. 

This option existed to fine tune the size of the initial chunk handed over to the boot class loader. That was done to speed up loading, since it was assumed that the boot class loader loads many classes and that the number of classes it loads is known and quite static. The speed up would result from the fact that the boot class loader calls less often back into the Metaspace allocator to obtain a new chunk.

However the underlying assumption that the number of classes loaded by the boot class loader is static and known is wrong since with the advent of CDS that number can vary greatly. Secondly, since with this proposal we are now able to commit large chunks on-demand, we can just hand a large uncommitted chunk to the boot class loader and let it commit that chunk as it allocates.


Alternatives
------------


Instead of modernizing the Metaspace allocator, we could get rid of it and allocate class metadata directly from C heap. The perceived advantage of such a move would be reduced code complexity.

The Metaspace allocator (both in its current and in its proposed improved form) is an arena-based allocator, similar to ResourceAreas or Compiler Arenas. An arena-based allocator exploits the fact that data are not released individually but have a common lifetime and can be released in bulk. In case of Metadata that lifetime is bound to the class loader.

A general purpose allocator like malloc on the other hand needs to be able to release and reuse individual allocations at any time. Providing that ability comes at the cost of memory and CPU overhead. Because of that disadvantage, a customized arena based allocator will always be faster and achieve tighter memory packing than a general purpose allocator.

The C Heap allocator in particular has some further disadvantages:

- Since allocations cannot be placed into pre-reserved ranges, we cannot use them to allocate Klass structures and convert their pointers into a narrow format by adding a common offset. In other words, the Compressed Class Space as it exists today would not work, we would have to re-imagine the way class pointers are encoded into their narrow format. The current encoding scheme is very effective and it would be difficult to find a similarly effective way to encode them.

- Relying too much on the libc allocator for a product which spans multiple platforms brings its own risk. At SAP we have experience with porting software across a large range of platforms. libc allocators can come with their own set of problems, which include but are not limited to high fragmentation, inelasticity and the infamous sbrk-hits-java-heap issue. Working together with vendors to solve these problems can be work- and time-intensive, if possible at all, and easily negate the advantage of reduced code complexity.

Nevertheless, a prototype was tested which completely rewires Metadata allocations to C Heap - so, every Metadata allocation was allocated with malloc(), and upon Class Loader death, each of these allocations was freed via free() [\[3\]](#footnote3). This experiment was done on Debian with glibc 2.23. The VM as well as a comparison VM using the new Metaspace prototype were ran through a micro benchmark involving heavy class loading and unloading. CompressedClassPointers were switched off as to not disadvantage the malloc-only variant.

The malloc-only variant showed the following differences to the comparison VM:

- Performance was reduced by about 8-12% depending on the number and size of loaded classes.
- Memory usage (process RSS) went up by 15-18% for class load peaks without class unloading involved [\[2\](#footnote2).
- With class unloading it was observed that process RSS did not recover at all from usage spikes. The VM became very inelastic. This led to a difference in memory usage of 153% [\[2\](#footnote2).

Note that the test was done with the compressed class space switched off. Since compressed class space comes with its own benefits in terms of memory footprint, the comparison would be even worse for the malloc variant.


Testing
-------

A side effect of a new Metaspace implementation would be better isolation of sub components which makes for better testability. This will result in more and better gtests.

Extensive function- and performance tests will be part of this work.

Risks and Assumptions
---------------------

### Virtual memory fragmentation and uncommit speed

An important part of this proposal is the ability to uncommit and recommit at reasonable speed. We are at the mercy of the underlying OS here. In particular, two potential issues stick out:

1) Uncommitting memory may be slow. We never saw this in practice but it may happen in theory. Metaspace reclamation happens as part of class unloading which may, depending on the collector involved, happen in a GC pause. Slow uncommitting would increase the pause time.

2) Every OS needs to manage virtual memory ranges. Uncommitting memory may fragment these ranges and increase their number. On Linux in particular, vm ranges are represented by an instance of vm_area_struct, which are kept in both a list and a lookup tree. Increasing the number of ranges may increase lookup time for virtual memory areas. Also, there are limits to how many mappings (areas) a process can have.

Note that both issues have been no concern in reality so far.

Mitigation/Contingency plans:

For (1), should uncommit times turn out to be problematic, uncommitting could be offloaded to an own thread and be done concurrently to the running application outside of a GC pause. This would increase coding complexity, so it should only be done if necessary.

For both (1) and (2), increasing commit granule size and/or uncommit threshold would decrease virtual memory fragmentation and decrease number of uncommit operations. In extreme cases we could switch off uncommitting altogether. The result would be a allocator working very similar to how Metaspace works now.

### Maximum size of metadata

The proposed design imposes an implicit limit to the maximum size a single piece of metadata can have, which is limited by the largest chunk size (root chunk size). The root chunk size is currently designed to be 4M, which is sized to be comfortably larger than the largest possible size of an InstanceKlass (about ~512K).

There are several ways to work around this limit should this turn out to be a problem:

- Easiest would be to increase the root chunk size. This is generally harmless but has subtle consequences for the granularity of reserved space, see Backward compatibility notes.

- Alternatively, should that not be sufficient, multiple neighboring root chunks can be chained together to house the metadata.

----

<a name="footnote1"></a>
[1] See jdk/sandbox repository, "stuefe-new-metaspace-branch": http://hg.openjdk.java.net/jdk/sandbox/shortlog/b537e6386306

<a name="footnote2"></a>
[2] https://github.com/tstuefe/JEP-Improve-Metaspace-Allocator/blob/master/test/test-mallocwhynot/malloc-only-vs-patched.svg

<a name="footnote3"></a>
[3] http://cr.openjdk.java.net/~stuefe/JEP-Improve-Metaspace-Allocator/test/test-mallocwhynot/readme.md