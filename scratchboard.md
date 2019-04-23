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

Humongous chunks:
Not needed anymore. Were needed for two reasons:
1) to satisfy large allocations beyond 64K
2) to pre-allocate large space for bootstrap

Both can be done by either:
  (a) allocating a large buddy-style chunk (e.g. 4MB). With the new notion of chunk-commits-on-demand,
  it is not so important anymore that chunks are small to not waste memory. So we can afford the "waste" we get by allocating
  large size-aligned chunks where needed.
  (b) if that hits some limit for some reason, we may just allocate certain chunks via malloc. We are talking about 2-4 chunks
  per VM run, typically only the boot cl. Those chunks would be freed at a place where other chnks would be given back
  to the freelists.
    
- we can get rid of:
  - occupancy map
  - chunkindex
  - humongous chunks
