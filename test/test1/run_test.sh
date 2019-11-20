EXT_OPTS=

ALL_OPTS="-XX:+AlwaysPreTouch -Xmx50M -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 ${EXT_OPTS}"


../jdk-original/bin/java ${ALL_OPTS} -XX:VitalsFile=original -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-standard -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-aggressive -XX:MetaspaceReclaimStrategy=aggressive -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y

