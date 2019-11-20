EXT_OPTS=

ALL_OPTS="-XX:+AlwaysPreTouch -Xmx100M -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 ${EXT_OPTS}"

TEST_OPTS="--num-classes=1 --num-loaders=8000"

../jdk-original/bin/java ${ALL_OPTS} -XX:VitalsFile=original -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y ${TEST_OPTS}
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-standard -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y ${TEST_OPTS}
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-aggressive -XX:MetaspaceReclaimStrategy=aggressive -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y ${TEST_OPTS}

