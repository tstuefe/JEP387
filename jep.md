(This is a draft for a possible future JEP improving the metaspace allocator)

# Improved metaspace allocator

Summary
-------

Enhance the metaspace allocator to reduce memory footprint and to return memory to the OS in a more timely manner.

Goals
-----

- Improve memory elasticity for metaspace. In its current form, memory is often retained by the VM even when classes are unloaded; that memory may be reused for future metaspace growth but that may never happen.

- Reduce amount of memory waste for space in use by a life class loader.

- Simplify metaspace coding and make it cheaper to maintain and easier to experiment with.


Non-Goals
---------

- Replacement of metaspace allocator with a different mechanism (e.g. malloc).

- Wholesale change of metaspace architecture.

Success Metrics
---------------

Metaspace memory footprint should be reduced. Amount of unused metaspace memory retained by the VM should be reduced. Metaspace coding should be more maintainable.


Motivation
----------

Metaspace uses more memory than needed to store class metadata. While that is not completely avoidable, the waste/usage ratio can get excessive when certain pathological allocation pattern happen (e.g. many shortlived class loaders). Furthermore, spikes in memory footpring due to high metaspace usage are often partly retained by the VM even when the spike has subsided again.

Memory is mostly wasted in two places:

Unused space in chunks in use: when a classloader allocates metaspace, it gets handed a chunk for its exclusive use. The size of that chunk is a guess toward the assumed future allocation behaviour of the loader. A loader which is assumed to load many more classes is given a large chunk, to prevent frequent callups into metaspace; a loader which is assumed to not need much space (e.g. Reflection loaders) will be given a very small chunk to reduce memory waste.

Loader usually stop loading classes at some point and often never resume class loading. In that case, the unused part of its current chunk is wasted. This waste ratio is especially high for loaders which did not load many classes and are on its first or second small chunk.

Free chunks: when a loader gets unloaded, all its chunks are returned to a free list. Those chunks may be reused for future allocation, but that may never happen or at least not in the immediate future. In the meantime that memory is retained by the VM and lost to the OS. There is a mechanism in place to return that memory to the OS (VirtualSpaceNode::purge()), but that only works with low fragmentation, and not for the class metaspace.

Both types of waste may add up to substantial losses in pathological cases. This is particularly disadvantageous in container environments where resources are paid by use. In addition, there is very little control today of when memory is returned to the OS. Since both returning memory and retaining memory may be called for in various situations, more control would be a good thing.

Description
-----------

The proposed implementation changes come in three parts:

Part A)

Change chunk geometry to reduce fragmentation

Currently there exist three kinds of chunks, traditionally called "specialized", "small" and "medium", sized 1K/4K/64K (64bit, non-class case, not counting humongous chunks). Size ratio between "specialized" and "small" is 1:4, between "small" and "medium" 1:16. These odd ratios increase fragmentation unnecessarily and hamper in a number of ways:

When allocating from metaspace, a chunk is needed large enough to hold the allocation. Today, where a loader needs 5K of metaspace memory, a small chunk of 4K size would be insufficient and it would be given a full medium chunk of 64K. Even worse, if the freelist only contains small 4K chunks, that 64K chunk would have to be allocated from virtual memory.

When classes are unloaded, the corresponding metaspace is returned and added to freelists. It is compacted where possible - chunks are merged with neighboring free chunks. However, we need 16 small chunks to be free to form one "medium" 64K sized chunk. A single chunk in that range still in use will prevent us from merging a 64K chunk.

How to do this better:

Replace the hard-wired "three chunk types" system with one where chunks are sized in power-of-two steps from a minimum (1K) to a maximum (64K). It would increase chances of getting chunks close to the desired size and increase chances of chunk merging, thus reducing fragmention of free chunks.

This is very close to a traditional buddy allocation style. However no tree structure would be needed; it can be implemented using the mechanisms existing today.

It would be beneficial toward code complexity: many operations, including fusing and splitting chunks, would become simpler.

Note: chunk allocation sequence - the order in which a loader is given chunks of which size - would not have to be changed. That is because the old chunk sizes (1K/4K/64K) clearly map to new chunk sizes. However, we should implement that sequence in a cleaner way, allowing for easy modification and experimentation.


-------

Part B)

Intra-chunk waste for used chunks could be reduced with two techniques. Both ways are complementary and may be implemented independently from each other.

B1) "Unused chunk space stealing"

Iterate over all life class loaders. For each loader, "prune" its current chunk: split the unused parts off, form new chunks from it and and put them into a freelist. To effectively work, this needs Part (A) implemented.

Example: A loader is using only the first 12K of a 64K chunk. In that case, we could split that 64K chunk into three chunks sized 16K|16K|32K and return the latter two to the freelist.

The assumption here is that the loader will not continue to load classes, at least not in the immediate future, and therefore the freed chunks will not immediately reallocated by it. A natural point to do this pruning would be when handling a Metaspace OOM. It also could happen independently from OOMs at certain periodic intervals. It could be combined with a heuristic which tries to guess whether the loader stopped loading classes - e.g. if it did not load classes for a certain time period.

B2) Late-committing chunks:

Currently, memory is committed in a coarse-grained fashion in the lowest allocation layer, in VirtualSpaceNode. Each node is a ReservedSpace with a commit watermark; all allocated chunks are completely contained by the committed region.

This could be changed: For chunks spanning multiple pages, each chunk could maintain its own commit boundaries. The first page, containing the chunk header, would obviously always have to be committed; however, the rest of the chunk pages could be committed on demand only when the chunk fills up.


The effect of (B1) would be that excessive waste in in-use chunks is reduced.

The effect of (B2) would be that wasted memory in in-use chunks does not count toward the overall resident set size of the process. The performance effects of excessive use of commit/uncommit would have to be examined.

-----

Part C)

Free chunks:

Chunks in the free list are wasted as long as they are not reused, which may be never or not for a long time. They could be uncommitted for as long as they reside in the freelist, returning their memory to the OS.

As with (B2), since the first page of a chunk contains its header, it cannot be uncommitted. But for chunks spanning multiple pages, all pages following the header page could be uncommitted. 

Since we merge chunks when adding them to the freelist - which would be way more efficient with Part (A) implemented - the chance of chunks spanning multiple pages is good.


----



Alternatives
------------

-TBD

Testing
-------

// What kinds of test development and execution will be required in order
// to validate this enhancement, beyond the usual mandatory unit tests?
// Be sure to list any special platform or hardware requirements.

- TBD -
 
Risks and Assumptions
---------------------

// Describe any risks or assumptions that must be considered along with
// this proposal.  Could any plausible events derail this work, or even
// render it unnecessary?  If you have mitigation plans for the known
// risks then please describe them.

- TBD -

Dependencies
-----------

// Describe all dependencies that this JEP has on other JEPs, JBS issues,
// components, products, or anything else.  Dependencies upon JEPs or JBS
// issues should also be recorded as links in the JEP issue itself.
//
// Describe any JEPs that depend upon this JEP, and likewise make sure
// they are linked to this issue in JBS.

- TBD -
