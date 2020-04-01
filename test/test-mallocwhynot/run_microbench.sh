# Notes: to be able to compare fairly:
# 1. -XX:-UseCompressedClassPointers since a malloc based solution cannot use compressed class space.
# 2. -XX:MetaspaceReclaimStrategy=none since the malloc based solution is not elastic.

# Note: UseNewCode3 to activate the malloconly solution


for i in {1..3}; do

echo "with-malloc"
time ../jdk-patched-mallocwhynot/bin/java -XX:-UseCompressedClassPointers -XX:+UnlockDiagnosticVMOptions -XX:+UseNewCode3 -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y  --nowait --num-loaders=500 --num-classes=300 --class-size=3 --wiggle=1.0

echo "patched"
time ../jdk-patched/bin/java -XX:-UseCompressedClassPointers -XX:MetaspaceReclaimStrategy=none -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y  --nowait --num-loaders=500 --num-classes=300 --class-size=3 --wiggle=1.0

done
