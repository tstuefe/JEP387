EXT_OPTS=

ALL_OPTS="-XX:NativeMemoryTracking=summary -XX:+AlwaysPreTouch -Xmx50M -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 ${EXT_OPTS}"

# need to run both without compressed class pointers to have a fair comparison
ALL_OPTS="${ALL_OPTS} -XX:-UseCompressedClassPointers"

../jdk-patched-mallocwhynot/bin/java ${ALL_OPTS} -XX:+UnlockDiagnosticVMOptions -XX:+UseNewCode3 -XX:VitalsFile=with-malloc -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-standard -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-aggressive -XX:MetaspaceReclaimStrategy=aggressive -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y

