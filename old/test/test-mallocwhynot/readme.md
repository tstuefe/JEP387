## Test goals

Show how much a switch to a malloc-only metadata allocation would cost us.

Malloc-only metadata allocation means:

- All allocations are done via os::malloc()
- All allocations have to be released when the SpaceManager dies with os::free()
- Deallocations have to be handled as well, so deallocated blocks have to be released with os::free() too.


### Patch implementation

The patch was implemented as follows:

SpaceManager::allocate() was wired directly to os::malloc(). In order to spare us from having to chase down all metadata allocation at death time and reducing the error rate, all metadata allocations where prefixed with a header which implemented a double linked list. All allocations where linked to the loading SpaceManager that way. We need a double linked list to efficiently remove blocks from the SpaceManager when blocks are deallocated.

Upon SpaceManager death, the list is walked and all metadata allocations are released.

In SpaceManager::deallocate, the deallocated block was removed from its list and freed.

### Test Notes

- We execute a heavy load/unload test with a bit of timewise interleaving (de.stuefe.repros.metaspace.InterleavedLoaders2).

- Since the patch does not implement any Metaspace statistics, all we can do is to measure process RSS from the outside.

- Adding a prefix to metadata allocations increases the number of allocated bytes per allocation by two words. Assuming that a more polished malloc-only implementation could do without the linked list, we want to measure the memory overhead of this header. Since all allocations are allocated from C-Heap, we can and did measure that using NMT. See below for numbers.

- Since the malloc-only variant is unable to provide a compressed class space, we execute the test without compressed class pointers.

- We compare the malloc-only variant with the latest incarnation of the JDK-8221173 prototype.

- Of course release builds were compared, and for the final RSS measurement NMT was switched off, so no additional cost apply to the malloc-only solution.

- All tests were done on Debian using glibc 2.23.

### Test results:

The test loads classes in five batches, the unloads all but one batch, then loads again five batches (thus bringing the total number of loaded batches to six), unloads them all. This produces two spikes in metadata usage and one valley inbetween.

- Performance: The malloc-only variant took between 8-12 % longer to finish, depending on the number and size of loaded classes.

- Memory usage: At the fist spike (before the first class unloading happening), we see an increase in RSS of about 18% (588M -> 697M). NMT showed us beforehand that the additional cost for the headers was at about 10M. If we factor that in we still see an increase of about 16% in RSS.

- Memory elasticity: After the first class unloading it can be seen that the malloc-only variant clings to its memory and is almost completely unelastic. Even though all metadata were released to the C-Heap, RSS did not go down at all (a well known effect of C heap allocators on many platforms). For our test this means that compared to the JDK-8221173 prototype, which almost completely recovers from the RSS spike, the malloc-only variant keeps its high RSS footprint. This leads to a delta in RSS after the first class unloading of over 180% (691M vs 240M).

Raw data: see comparison.ods

### Final notes

Note that this test and the interpretion of its results actually favour the malloc-only variant: 

Executing without compressed class space imposes a penalty in memory usage, so in real life - with the comparison VM using compressed class space - the delta in RSS would be even more lopsided. However that effect is difficult to measure since it heavily depends on the object number and -granularity. In our experience, compressed class space brings about 3-6% or RSS reduction.

Moreover, removing the cost for the prefix headers from the malloc-only variant implies that a more polished implementation comes without any additional VM-side overhead both in performance and RSS, whereas the other side, JDK-8221173 prototype, also has overhead which will be further reduced with future enhancements. In short, above we compared an idealized malloc-only variant with a current-state JDK-8221173 prototype.





