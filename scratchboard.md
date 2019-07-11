# Notes

- chunksizes:
	
	MIN_CHUNK_SIZE = 1K (because that is large enough for 99% of InstanceKlass)
	max chunk size should be at least 2M, better 4M. That is large enough to capture the largest InstanceKlass theoretically possible. Reasoning:
		- we want to get rid of humongous chunks. In non-class metaspace we can, as a fallback, always allocate a chunk from C-heap if it turns out our largest chunk size we planned for was not large enough. But in class-space we cannot. Since in class space only Klass structures live and those are the largest things we will see, those will determine the largest chunk size. Largest I can recreate with my little arms are ~512K (with 32000 methods, 32000 interface methods).
	-> therefore lets assume 4M.
	-> therefore MAX_NUM_LEVELS = 12
	MAX_NUM_LEVELS = 12
	MAX_CHUNK_SIZE = 1K << MAX_NUM_LEVELS (4MB) 

- chunk:
8	- owner (?) (debug - space mgr or chunk mgr)
8	- container (still needed since we need to know the borders for safe coalescation)
16	- prev next (either points to freelist or spacemgt list)
1	- level (0 = smallest, e.g. 512) -> determines size() 
1	- flags (is_free)
2	- num_pages_committed (16bit => 256mb chunks) or, for simplicity, commit boundary ptr
4	- sanity eyecatcher (debug)

- chunkmanager
	- now has MAX_NUM_LEVELS freelists
	- changed operations:
		- add chunk:
			- coalesce that chunk with its neighbors
			- if the resulting chunk is over threshold, uncommit portion of it

- new class: ChunkProgression
	- defines the strategy taken to hand out chunks to class loaders
	- assigned to SpaceManager
	- has:
		- ideal_progression: sequence of levels or sizes, e.g. 4K-4K-4K-64K for normal classloaders
		- somehow (?) model "willingness" to use other chunk sizes
			- should depend on the number of free chunks in chunkmanager, as well as a certain global threshold
		- Simple example:
			- have a "not below" per level, e.g. "4K but not-below 2K"
			- have a "not above" per level, beyond which we would split chunks

- virtualspacenode:
	- remove occupancy map
	
	- operations:
		create new chunk:
			- carve chunk out of raw memory
			- always largest chunk size? 

-----

- metachunks:
	- buddy allocation:
		- have a way to find the sibling chunk
		- chunks have a "level" which corresponds to their size:
			level 0 > smallest level -> 1K
			up to level 12


--------------

-> we do not need humongous chunks anymore since:
	- use case 1: a allocation is larger than max chunk size
		-> can be covered with just upping the largest possible chunk size. e.g. a max chunk size of 4MB should be sufficient. But VSpace node size (for non class) may be upped accordingly too, e.g. to 16MB. This will decrease chances of node purging but that is fine;  since this JEP will improve elasticity node purging will not be the primary mechanism to return memory to the OS anymore.
		-> fallback: just malloc those chunks. Which would work fine for non-class metaspace; for class metaspace of course not since chunk must be located in compressed class space, but here, there is a cap to the max possible allocation size - a Klass can only get so large. (a class with 32000 methods and 32000 interfaces will be about 500K, so a max chunk size of e.g. 4MB should be comfortably sufficient).
		-> Overhead: another intent of the humongous chunks was to limit memory usage to just the amount needed without internal fragmentation (e.g. allocating 65K should just use 65K, not 128K). But since the aim of this JEP is to uncommit unused parts of larger metachunk, this should not play any role anymore.


- we can get rid of:
  - occupancy map
  - chunkindex
  - humongous chunks


--------------------------

We move the chunk header out of the vs area. That reduces fragmentation on the memory mapping level a lot when uncommiting chunks, and it makes splitting chunks easier and cheaper since we do not have to commit the start of the split-off chunks to place the chunk headers.

The chunk headers are not independent structures organized in a binary tree. Each root node area has one assigned binary tree. The tree describes how the root node is splintered.

The tree itself can get large, so take care to keep the tree nodes small. That can be done by not using pointers but indices.

A tree node has:
- link to parent unless root
- link to sib
- link to firstborn child (leader buddy) unless leaf
- link to the metachunk structure if leaf

chunk headers are allocated from a global array. We can use 32bit ints to adress a chunk. When a node is merged, we have one chunk header left, it is kept in a global freelist.

A chunk has a reference to 

Chunk merging:
- get sibling chunk via chunk-

















- We 




