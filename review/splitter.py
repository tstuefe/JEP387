# !/usr/bin/env python3

import sys

file1 = open('jep387-all.patch', 'r')

lines = file1.readlines()

files_and_destinations = (
    # <name>, <patch file>

    # order matters: order these patterns in order of speciality

    # match misc unless...
    ('/src', 'misc'),

    # everything in memory/metaspace shall be core unless ...
    ('/src/hotspot/share/memory/metaspace/', 'core'),

    # all these files go to misc
    ('/src/hotspot/share/memory/metaspace/metaspaceDCmd', 'misc'),
    ('/src/hotspot/share/memory/metaspace/metaspaceSizesSnapshot', 'misc'),
    ('/src/hotspot/share/memory/metaspace/printCLDMetaspaceInfoClosure', 'misc'),
    ('/src/hotspot/share/memory/metaspace/printMetaspaceInfoKlassClosure', 'misc'),

    # or to test
    ('/src/hotspot/share/memory/metaspace/metaspace_test', 'test'),

    # core
    ('/src/hotspot/share/memory/metaspace.hpp', 'core'),
    ('/src/hotspot/share/memory/metaspace.cpp', 'core'),

    ('/src/hotspot/share/prims/whitebox', 'test'),

    # anything in test go to test
    ('/test', 'test'),

)

lines_core_patch = []
lines_misc_patch = []
lines_test_patch = []

count = 0
destination = None

for line in lines:
    #print("line {} ;  {}".format(count, line.strip()))
    #count = count + 1
    if line.startswith('diff --git'):
        for match in files_and_destinations:
            if line.startswith('diff --git a' + match[0]):
                destination = match[1]
        if destination is None:
            sys.exit('no rule for: ' + line)
        print(line.strip() + " -> " + destination)

    if destination is not None:
        if destination == 'test':
            lines_test_patch.append(line)
        elif destination == 'core':
            lines_core_patch.append(line)
        elif destination == 'misc':
            lines_misc_patch.append(line)


file = open('jep387-core.patch', 'w')
file.writelines(lines_core_patch)
file.close()

file = open('jep387-test.patch', 'w')
file.writelines(lines_test_patch)
file.close()

file = open('jep387-misc.patch', 'w')
file.writelines(lines_misc_patch)
file.close()

if len(lines_core_patch) + len(lines_test_patch) + len(lines_misc_patch) < len(lines) - 8:
    sys.exit("too few lines")


#print('CORE')
#print(*lines_core_patch, sep = "\n")

#print('TEST')
#print(*lines_test_patch, sep = "\n")

#print('MISC')
#print(*lines_misc_patch, sep = "\n")



