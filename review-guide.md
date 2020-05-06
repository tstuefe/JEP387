## Preface

This is a review guide and an architectural description of the new Elastic Metaspace. Its main intent is to make life easier for Reviewers of the patch, but also to give a better understanding of the mechanics behind Metaspace.

------

Suggested reading:

For a very short (~20min) introduction into Metaspace, both old and new, the presentation we gave at Fosdem20 is a good starting point:

Vid: https://www.youtube.com/watch?v=XqaQ-z70sQs

Slides: https://www.slideshare.net/ThomasStuefe/taming-metaspace-a-look-at-the-machinery-and-a-proposal-for-a-better-one-fosdem-2020

A somewhat longer presentation I gave to Oracle employees in March 2020:

Slides: https://github.com/tstuefe/JEP-Improve-Metaspace-Allocator/blob/master/pres/metaspace2.pdf

------

## Metaspace in three paragraphs or less

Metaspace is used to manage memory for Metadata. 

It is in its core an [arena-based allocator](https://en.wikipedia.org/wiki/Region-based_memory_management). This is because Metadata are tied to their classes, which usually are tied to their class loaders and live just as long; unloading a class loader will make all classes collectable, which will in turn release all their Metadata in one go -> burst free scenario.

## Concepts

Please see the [JEP draft](https://openjdk.java.net/jeps/8221173) and above mentioned materials for details. Here just a short recapture:

### Commit Granules

Memory underlying the Metaspace is divided into commit granules. This is the basic unit of committing, uncommitting.

A commit granule is typically 64K in size. Its size is a compromise between virtual memory area fragmentation and the desire to uncommit free memory to return it to the system.

The smaller a commit granule is, the more likely it is to be unoccupied and eligible for uncommitting. But at the same, uncommitting very small areas will increase the number of memory mappings of the VM process.

The default size is 64K with `-XX:MetaspaceReclaimStrategy=balanced`. Switching to `-XX:MetaspaceReclaimStrategy=aggressive` switches granule size to 16K (4 pages on most platforms). The latter gives better results in scenarios with heavy usage of anonymous classes, e.g. Lambdas.

### The Buddy Style Allocator

Memory in Metaspace is managed in chunks. In this granularity memory is handed to class loaders. 

Chunks vary in size. Largest size is 4M ("Root Chunk"). Smallest size atm is 1K. Chunk sizes are power2 sizes.

Chunks are managed by a [buddy allocator](https://en.wikipedia.org/wiki/Buddy_memory_allocation). A buddy allocator is a very simple very old algorithm which is useful to keep fragmentation at bay, at the cost of limiting the size of managed areas to power of two units. This restriction does not matter for Metaspace since the chunks are not the ultimate unit of allocation, just an intermediate.

In code, chunk size is given as "chunk level" (`typedef .. chklvl_t`). A root chunk - the largest chunk there is - has chunk level 0. The smallest chunk has chunk level 13. Helper functions and constants to work with chunk level can be found at chunk_level.hpp.


## Outside usage

The outside interface to the Metaspace (ignoring reporting/monitoring for now) are:
- the ClassLoaderMetaspace class
- the Metaspace static "namespace"

class ClassLoaderMetaspace is the holder for above mentioned arenas; it belongs to a class loader (more accurately, to a CLD). When released (in the wake of a GC collecting the owning loader and its CLD) it will release all Metaspace back to the system.


# Subsystems

The new Metaspace is separated into various subsystems which are rather isolated and can get reviewed independently from each other.

## The Virtual Memory Subsystem

The Virtual Memory Layer is the lowest subsystem of all. It is responsible for reserving and committing memory. It has knowledge about commit granules (the granularity at which we commit in Metaspace).

Its outside interface to upper layers is the class VirtualSpaceList; some operations are also directly accessed via a node in this list (VirtualSpaceNode).

A VirtualSpaceList is a list of reserved regions (VirtualSpaceNode). It is a global structure: only one instance of this structures exists per process. It grows on demand (new reserved regions are added when more space is needed). Regions in this list are typically several MB sized (atm 8M = 2 Root chunks areas, see below).

If we use CompressedKlassPointers, a second global instance of VirtualSpaceList exists, which holds the compressed class space. In that case the VirtualSpaceList is degenerated: it only ever has one node, sized as big as the CompressedClassSpaceSize (1G).

### Essential operations

- "Give me a new root chunk"

	`VirtualSpaceList::Metachunk* allocate_root_chunk();`

    This carves out a new root chunk (a chunk of maximum size of 4M) from the reserved space and hands it up to the caller. This operation is independent on any committed/uncommitted notion. Memory below this chunk does not have to be, and often is not, committed.

- "commit this range"

	`VirtualSpaceNode::ensure_range_is_committed()`

    Memory is divided into "commit granules". This is the basic unit of committing/uncommitting. Only this subsystem knows about these.

    The subsystem knows which granules are committed - it keeps the commit state of granules in a bitmask.
 
    In contrast to old Metaspace, the committed areas do not have to be contiguous. Any granule can be committed or uncommitted independent from their neighbors.

    Upper layers can request that a given address range should be committed. Subsystem figures out which commit granules are affected and makes sure those are committed. This may be fully or partly a NOOP if the range is already committed.

	When committing, subsystem honors limits (either GC threshold or MaxMetaspaceSize).

- "uncommit this range"

	`VirtualSpaceNode::uncommit_range()`
	
    Similar to committing. Subsystem figures out which commit granules are affected, and uncomits those.

- "purge"
	
    `VirtualSpaceList::purge()`

    This unmaps all completely empty memory regions.


### Other operations

The Virtual Memory Subsystem takes care of a number of operations which do not necessarily have to do with virtual memory management. This is a bit historic (earlier versions of the Elastic Metaspace prototype worked differently).

These operations have to do with the Buddy Style Allocator behind the chunk management:

- "split this chunk, maybe repeatedly"
	`VirtualSpaceNode::split()`
- "merge up chunk with neighbors as much as possible"
	`VirtualSpaceNode::merge()`
- "enlarge chunk in place"
	`VirtualSpaceNode::attempt_enlarge_chunk()`

These operations the subsystem does on behalf of the ChunkManager.


### Classes

#### class VirtualSpaceList

A VirtualSpaceList is a list of reserved regions (VirtualSpaceNode). 

It is a global structure: only one or two VirtualSpaceList instances exist per process. 

VirtualSpaceList grows on demand - new reserved regions are added when more space is needed. Regions are several MB sized (atm 8M = 2 Root chunks areas, see below).

If `-XX:+UseCompressedClassPointers`, a second global instance of VirtualSpaceList exists, which holds the "compressed class space" (see Concepts). That instance is a degenerated version of a list; it only ever has one node which is sized as big as the CompressedClassSpaceSize (1G). New nodes cannot be added.

#### class VirtualSpaceNode

Has a very central role.

A VirtualSpaceNode manages one contiguous reserved region of the Metaspace. In case of the compressed class space, this is the whole compressed class space.

It knows which granules in this region are committed by maintaining a bitmask (class CommitMask).

VirtualSpaceNode also knows about root chunks: the memory is divided into a series of root-chunk-sized areas (class RootChunkArea). This means the memory has to be aligned (both starting address and size) to root chunk area size of 4M.

```

| root chunk area               | root chunk area               |

+---------------------------------------------------------------+
|     VirtualSpaceNode memory                                   |
|                                                               |
+---------------------------------------------------------------+

|x| |x|x|x| | | | |x|x|x| | | |x|x| | | |x|x|x|x| | | | | | | | | commit granules

(x = committed)

```

One root chunk area can contain a root chunk or a number of smaller chunks. E.g. splitting off a 64K chunk from a 4M root chunk will split the chunk into: 2x64K, 1x128K, 1x256K, 1x512K, 1x1M, 1x2M. But note that the VirtulSpaceNode has no knowledge of this, nor does it care.

Note that the concepts of commit granules and of root chunks and the buddy allocator are almost completely orthogonal; at this layer, they exist independently from each other.

#### class CommitMask

Very unexciting. Just a bit mask holding commit information, with a notion about which memory each bit covers.

#### class RootChunkArea and class RootChunkAreaLUT

The class RootChunkArea encapsulates the Buddy Style Allocator implementation. It is wrapped over the area of one root chunk and manages buddy operations in this area.

It knows how to split and merge chunks buddy-style-allocator-style.

(Arguably this could also be done somewhere else, e.g. by the ChunkManager itself, or even within the Metachunk class. But I needed a place to put this functionality, and in former implementations the Buddy Allocator implementation was more involved and needed more state.)

The class RootChunkAreaLUT (for "lookup table") just holds a sequence of RootChunkArea classes which cover a contiguous memory range containing multiple root chunks. It offers lookup functionality "give me the RootChunkArea for this address".

Within the context of a VirtualSpaceNode, it just is the collection of all RootChunkAreas contained in the memory of this node.

#### class CommitLimiter

The commit limiter exists to separate the logic of "am I allowed to commit X words more for Metaspace purposes, or would I hit GC threshold or MaxMetaspaceSize?".

It exists to remove knowledge about the GC and about limits like MaxMetaspaceSize from the Virtual Memory Subsystem. It just offers an interface to ask "is it okay to commit".

Under normal circumstances, only one instance of the CommitLimiter ever exists, see CommitLimiter::globalLimiter(), which encapsulates the GC threshold and MaxMetaspace queries.

But by separating this functionality from Metaspace, we get better testeability: we can plug in a Dummy CommitLimiter and thus effectively disabling or modifying the limiting; that way we can write gtests to test this subsystem without having to care about global state like how much Metaspace the underlying VM used up already.


## The Central Chunk Repository, aka ChunkManager

This subsystem plays a very central role. It only consists of one class, `class ChunkManager`.

There only exists one central instance of the ChunkManager (two if `-XX:+UseCompressedClassPointers`).

The ChunkManager is the central point to hand out chunks of any given level (size). 

It keeps lists of free unused chunks and tries preferably to satisfy requests by pulling chunks from the freelists.

It sits atop of the Virtual Memory Subsystem. If needed, it will request new root chunks from it to refill the free lists.

### Basic operations

- "Give me a chunk of level X"

    `ChunkManager::get_chunk(..)`

    This will provide a chunk to the upper layer of the requested size. It may pull the chunk from a freelist, maybe splitting larger chunks to do that. It also may allocate a new root chunk from the Virtual Memory Subsystem to satisfy the request.

- "I do not need this chunk anymore, keep it"

    `ChunkManager::return_chunk()`

    Callers call this (typically a SpaceManager before its death) to hand down newly free chunks to the ChunkManager for safekeeping. ChunkManager will put them into the freelist. Before doing this, it will attempt to merge the chunks Buddy-Allocator style with its neighbors to arrive at larger chunks.

    If, after merging with neighbors, the resulting free chunk surpasses a certain threshold, its memory is uncomitted.


## Classloader-local subsystem

The previous sub systems were all global structures. The Classloader-local subsystem encompasses all Classes whose instances are tied to a class loader.

This sub system builds atop the Central Chunk Repository, the ChunkManager, and indirectly atop the Virtual Memory Subsystem.

It offers fine granular allocation to the caller. A caller needing 240 bytes for a constant pool will get this memory from this layer. Therefore it can be seen as the topmost layer of Metaspace.

### Basic operations

- "Give me n words of memory from class space / non class space".

    `ClassLoaderMetaspace::allocate()`

    This will allocate n words of Metaspace. Internally the memory will be taken from a chunk via pointer bump allocation, similar to a thread stack. If no chunk exists or the current chunk belonging to the class loader is too small, a new chunk is obtained by asking the ChunkManager.

- "Release all Metaspace I ever allocated"

    `ClassLoaderMetaspace::~ClassLoaderMetaspace()`

    Called upon class loader death. This releases all memory ever allocated for this class loader, by returning all chunks it owns back to the underlying ClassLoaderMetaspace.

- "I do not need this piece of memory, please take it"

    `ClassLoaderMetaspace::deallocate()`

    See Deallocation Subsystem for details.

### Classes

#### class Metachunk

Metachunk wraps one chunk - be it a root chunk of 4M or a small chunk of 1K.

Metachunk knows its chunk memory area (base address and size aka level).

MetaChunk and its payload area are disjunct. In the old Metaspace, MetaChunk was a header, followed by the chunk payload. Elastic Metaspace separates those two, removing the headers from the payload and from Metaspace altogether. For details, see class ChunkPoolHeader below.

It also knows the underlying VirtualSpaceNode whose memory it resides in.

A Metachunk has a state. It is either "in-use", in which case it is owned by a class loader, and managed in its used-chunk-list. Or it is "unusued" and lives inside the freelist of the ChunkManager.

A third state is "dead" which just indicates a MetaChunk header without payload.

It usually lives in some form of chained list, together with other chunks, so it has a next/prev.

It also knows its neighboring chunks in memory - needed to efficiently do buddy style operations.

#### Metachunk Memory

A Metachunk which is "in-use" gets allocated from via pointer bump allocation, starting at base. So it has a used an unused part:

```
+------------------------------+--------------------------------------+
|     used                     |     unused                           |
+------------------------------+--------------------------------------+

^                              ^                                      ^
base                          used_words                              end.
```

The memory underlying a Metachunk may consist of any number of commit granules, which can be committed or uncommitted independently from each other. So the memory below a chunk could be "checkered".

Of course, the used portion of a Metachunk has to be committed, otherwise we could not store data in them. Therefore, when allocating new memory from the Chunk, before moving the top-pointer, MetaChunk ensures the newly used memory is committed by asking the underlying VirtualSpaceNode.

But since this is costly - we do not want to bother VirtualSpaceNode for every single allocation - MetaChunk also keeps record of the highest committed address in its range. Note that does not mean there could not be committed granules in higher areas; it just means it does not know better:

```
+------------------------------+-------------------+------------------+
|     used                     | unused committed  | unused unknown   |
+------------------------------+-------------------+------------------+

^                              ^                   ^                  ^
base                           used_words          committed_words    end.
```

So, space below committed_words is guaranteed to be committed; beyond that MetaChunk has to make sure by bothering VirtualSpaceNode.

-------------

A chunk can of course be smaller than a commit granule. In that case it shares that granule with its neighboring chunks. Since a commit granule can only be committed or uncommitted this means that if one of these chunks is "in-use" and needs to be committed, all chunks in this granule are committed.

--------------

Note that a chunk knows nothing about granules beyond their size, as an alignment hint for talking to VirtualSpaceNode. It just asks the VirtualSpaceNode to commit a range which may or may not cover multiple granules.

#### class SpaceManager

A central class.




## Deallocation subsystem

This is a sideshow but still important.



## Auxiliary stuff


todo

MetachunkList  		- a linked list of Metachunk. Maybe homogenous, maybe not.
MetachunkListVector  	- a list of MetachunkList, one for each possible chunk size (so, 13 ATM). 


- ChunkHeaderPool

- Counters






## Other information

### Locking and concurrency




