Summary
-------

Return unused class-metadata (i.e., _metaspace_) memory to the operating system more promptly, and reduce metaspace memory footprint.

Goals
-----

- Reduced metaspace memory footprint
- Better elasticity: metaspace should recover from usage spikes much more readily, returning memory to the operating system when possible.
- A cleaner metaspace implementation which should be less difficult to maintain

Non-Goals
---------

This proposal will not change the way compressed class pointer encoding works nor the fact that a compressed class space exists.

Even though it would be a possible future enhancement, it does not extend the use of the metaspace allocator to other areas of the hotspot. Its callers remain mostly unchanged.

Motivation
----------

Since its inception, metaspace has been somewhat notorious for high off-heap memory usage; while most normal applications don't have problems, it is easy to tickle the metaspace allocator in just the wrong way to cause excessive memory waste. Unfortunately these types of pathological cases are not uncommon. This can be improved.

Moreover, metaspace coding has grown complex over time and became difficult to maintain. A clean rewrite would help.

Description
-----------

### Preface

Since JEP 122 [\[1\]](#footnote1), class metadata live in non-java-heap memory ("metaspace"). Their lifetime is mostly bound to that of the loading class loader, so the metaspace allocator is at its heart an arena-based allocator [\[2\]](#footnote2).

It manages memory in per-classloader arenas, from which the class loader allocates via cheap pointer bump. When the class loader gets collected, these arenas are returned to the metaspace for future reuse.

### Proposed improvements

There are several waste areas within metaspace which a rewrite will address:

#### Elasticity

Memory returned to the metaspace by a collected loader is mostly kept in freelists for later reuse; however, that reuse may not happen for a long time, or it may never happen. Therefore applications with heavy class loading and -unloading may accrue a lot of unused space in the metaspace freelists.

Since memory in these freelists can only be reused for one specific purpose - further class loading - it would be better to return that memory to the Operating System for use in different areas. That would result in increased elasticity.

#### Per Classloader Overhead

There is a per-loader overhead in memory usage mainly caused by the granularity by which metaspace arenas can grow (_metaspace chunk size_). That granularity is somewhat coarse which can cause applications with fine granular class loader schemes suffer unreasonably high metaspace usage.

To improve this, it is proposed to change the allocator to a finer-granular growing scheme. Arenas can start off smaller and grow in a more fine controlled fashion, which would reduce the overhead per class loader especially for small loaders.

This can be done by switching metaspace memory management to a buddy allocation scheme [\[3\]](#footnote3). This is an old and proven algorithm used successfully e.g. in the Linux kernel. Not only would it reduce per-classloader overhead, it would also give us superior metaspace defragmentation on class unloading.

In addition to that, it is proposed to commit arenas lazily, only on demand. That would reduce footprint for loaders which start out with large arenas but will not use them immediately, or maybe never use them to their full extent, e.g. the boot class loader.

#### Checkered committing

In order for these proposals to work, the ability to commit and uncommit arbitrary ranges of metaspace is needed.

Where today metaspace is committed using a simple high-watermark system - and never really uncommitted - we would change that to one in which metaspace is segmented into homogeneously sized regions which could be committed and uncommitted independently of each other ("_commit granules_"). The metaspace allocator would keep track of the commit state of each granule. The size of these granules can be modified at VM start via a VM flag, which will be a simple way to tweak the trade off between commit granularity (and hence, memory savings by uncommit) and virtual memory fragmentation.

### Further information

A document detailing the proposal can be found at [\[6\]](#footnote6). A working prototype exists as a branch in the jdk-sandbox repository [\[7\]](#footnote7).

Alternatives
------------

Instead of modernizing metaspace, we could remove it and allocate class metadata directly from C heap. The advantage of such a move would be reduced code complexity.

Moving to the C-heap allocator would have the following disadvantages:

- As an arena-based allocator metaspace exploits the fact that class metadata are bulk-freed. The C-heap allocator does not have that luxury; using it would mean we would have to track and release each single meta datum individually which would increase runtime overhead, and, depending on how they are tracked, code complexity and/or memory usage.

- As an arena-based allocator metaspace uses pointer-bump allocation which achieves very tight memory packing. A C-heap allocator typically incurs more overhead per allocation.

- Using the C-heap allocator would mean we could not implement the compressed class space as we do today and would have to come up with a different solution for compressed class pointers.

- Relying too much on the libc allocator brings its own risk. C-heap allocators can come with their own set of problems, e.g. high fragmentation, poor elasticity and sbrk issues. Since these issues are not under our control, solving them requires cooperation with platform vendors, which can be work intensive and easily negate the advantage of reduced code complexity. This is based on the experience of long-term maintenance of software across many platforms at SAP.

Nevertheless, a prototype was tested which rewired Metadata allocation to C Heap [\[4\]](#footnote4). This experiment was done on Debian with glibc 2.23. The VM as well as a comparison VM using the new metaspace prototype were ran through a micro benchmark which involved heavy class loading and unloading. The compressed class space was switched off for this test since it would not work with C-heap allocation.

The following issues with the malloc-only variant were observed:

- Performance was reduced by about 8-12% depending on the number and size of loaded classes.
- Memory usage (process RSS) went up by 15-18% for class load peaks _without_ class unloading involved [\[5\](#footnote5).
- With class unloading, it was observed that process RSS did not recover at all from usage spikes. Metaspace was completely inelastic. This led to a difference in memory usage of up to 153% [\[5\](#footnote5).

Note that these numbers hide the memory penalty caused switching off the compressed class space; taking that into consideration would make the comparison even more unfavorable for the malloc-only variant.

Testing
-------

Part of this work will be:
- a new set of gtests
- one or more jtreg tests verifying the uncommit capability

Risks and Assumptions
---------------------

### Virtual memory fragmentation

Every OS manages its virtual memory ranges in some way (e.g. the Linux kernel uses a red-black tree). Uncommitting memory may fragment these ranges and increase their number. This may affect performance of certain memory operations. It also may cause the VM process to trigger system limits to the maximum number of memory mappings.

In practice, since the defragmentation capabilities of the buddy allocator are quite good, the increase in memory mappings by this proposal have been very modest so far. Should the increased number of mappings be a problem, we would increase the commit granule size, which would lead to coarser uncommitting. That would reduce the number of virtual memory mappings at the cost of some lost uncommit opportunities.

### Uncommit speed

Uncommitting large ranges of memory may be slow, depending on how the platform implements page tables and how densely the range had been populated before. Since metaspace reclamation may happen during a GC pause, this could be a problem.

No adverse affects of uncommitting have been observed so far; but should uncommit times be an issue, uncommitting could be offloaded to a separate thread to be done outside the GC pause.

### Maximum size of metadata

The proposed design would impose an implicit limit to the maximum size of a single meta datum, since it cannot be larger than the largest chunk size the buddy allocator manages ("_root chunk size_"). That root chunk size is currently set to be 4M and it is comfortably larger than anything we would want to allocate from metaspace.

Should this be a problem, there would be several ways to work around this limit, from simply increasing the root chunk size to merging two neighboring root chunks together.


----

<a name="footnote1"></a>
[1] https://openjdk.java.net/jeps/122

<a name="footnote2"></a>
[2] https://en.wikipedia.org/wiki/Region-based_memory_management

<a name="footnote3"></a>
[3] https://en.wikipedia.org/wiki/Buddy_memory_allocation

<a name="footnote4"></a>
[4] http://cr.openjdk.java.net/~stuefe/JEP-Improve-Metaspace-Allocator/test/test-mallocwhynot/readme.md

<a name="footnote5"></a>
[5] http://cr.openjdk.java.net/~stuefe/JEP-Improve-Metaspace-Allocator/test/test-mallocwhynot/malloc-only-vs-patched.svg

<a name="footnote6"></a>
[6] http://cr.openjdk.java.net/~stuefe/JEP-Improve-Metaspace-Allocator/review-guide/

<a name="footnote7"></a>
[7] http://hg.openjdk.java.net/jdk/sandbox/shortlog/38a706be96d4