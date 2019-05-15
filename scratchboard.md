# WIP

- chunksizes:
	
	MIN_CHUNK_SIZE = 1K (512?)
	MAX_NUM_LEVELS = 13 (14)
	MAX_CHUNK_SIZE = 1K << MAX_NUM_LEVELS (4MB)

- chunk:
8	- owner (?) (debug - space mgr or chunk mgr)
8	- container (still needed since we need to know the borders for safe coalescation)
16	- prev next (either freelist or spacemgt list)
1	- level (0 = smallest, e.g. 512)
1	- flags (is_free)
2	- num_pages_committed (16bit => 256mb chunks)
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
