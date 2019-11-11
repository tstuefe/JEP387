

XOPTS="--num-classes=1 --num-loaders=8000"


time ../jdk-patched/bin/java -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=patched-nolom -XX:-MetaspaceUseLOM -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y $XOPTS
time ../jdk-patched/bin/java -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=patched-lom -XX:+MetaspaceUseLOM  -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y $XOPTS
time ../jdk-original/bin/java -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=original -cp ../repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y $XOPTS
