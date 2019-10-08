./jdk-original/bin/java -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=original -cp ./repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y
./jdk-patched/bin/java -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=patched-standard -cp ./repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y
./jdk-patched/bin/java -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=patched-aggressive -XX:MetaspaceReclaimStrategy=aggressive -cp ./repros8-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders2 -y

