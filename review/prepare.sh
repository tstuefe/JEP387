#! /bin/bash


# Apply raw patch to jdk-jdk. Generate a webrev. From that webrev, copy the changeset
# and use this as the patch file for all.

cd /shared/projects/openjdk/jdk-jdk/source

hg qpop -a
hg pull -u
hg up -C default

hg qremove jep387-all.patch jep387-core.patch jep387-misc.patch jep387-test.patch 
hg qimport /shared/projects/openjdk/jep387/patches/jep387-all.patch
hg qpush --move jep387-all.patch

rm -rf /shared/projects/openjdk/jep387/review/webrev*
ksh /shared/projects/openjdk/code-tools/webrev/webrev.ksh -o /shared/projects/openjdk/jep387/review/webrev-all
hg qpop -a

###

cd /shared/projects/openjdk/jep387/review
rm jep387-*
cp webrev-all/webrev/source.changeset ./jep387-all.patch

# Now generate sub patch files

python3 splitter.py 

# print outs to double check
ls
wc -l jep387-*

###

# return to source dir. Apply each of the sub patches separately, and generate webrevs for those.

cd /shared/projects/openjdk/jdk-jdk/source

hg qremove jep387-all.patch 

# as a test, apply the big reformulated all patch
hg qimport /shared/projects/openjdk/jep387/review/jep387-all.patch
hg qpush --move jep387-all.patch
hg qpop

# apply core patch and generate webrev
hg qimport /shared/projects/openjdk/jep387/review/jep387-core.patch
hg qpush --move jep387-core.patch 
ksh /shared/projects/openjdk/code-tools/webrev/webrev.ksh -o /shared/projects/openjdk/jep387/review/webrev-core
hg qpop

# apply misc patch and generate webrev
hg qimport /shared/projects/openjdk/jep387/review/jep387-misc.patch
hg qpush --move jep387-misc.patch 
ksh /shared/projects/openjdk/code-tools/webrev/webrev.ksh -o /shared/projects/openjdk/jep387/review/webrev-misc
hg qpop

# apply test patch and generate webrev
hg qimport /shared/projects/openjdk/jep387/review/jep387-test.patch
hg qpush --move jep387-test.patch 
ksh /shared/projects/openjdk/code-tools/webrev/webrev.ksh -o /shared/projects/openjdk/jep387/review/webrev-test
hg qpop


