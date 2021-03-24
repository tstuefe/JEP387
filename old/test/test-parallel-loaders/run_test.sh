
EXT_OPTS=

ALL_OPTS="-XX:+AlwaysPreTouch -Xmx50M -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 ${EXT_OPTS}"



../jdk-original/bin/java ${ALL_OPTS} -XX:VitalsFile=original -cp ../examples-1.0.jar de.stuefe.repros.metaspace.ParallelLoaders -y
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-standard -cp ../examples-1.0.jar de.stuefe.repros.metaspace.ParallelLoaders -y
../jdk-patched/bin/java  ${ALL_OPTS}  -XX:VitalsFile=patched-aggressive -XX:MetaspaceReclaimStrategy=aggressive -cp ../examples-1.0.jar de.stuefe.repros.metaspace.ParallelLoaders -y



