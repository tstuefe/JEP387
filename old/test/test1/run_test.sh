EXT_OPTS=

ALL_OPTS="-XX:+AlwaysPreTouch -Xmx1G -XX:+UnlockDiagnosticVMOptions -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 ${EXT_OPTS}"

JAVA_HOME_1="/shared/projects/openjdk/jdks/sapmachine15"
JAVA_HOME_2="/shared/projects/openjdk/jdks/sapmachine16"

TEST_OPTS=''

echo "VM 1"
${JAVA_HOME_1}/bin/java ${ALL_OPTS} -XX:VitalsFile=vitals_old_1 -XX:StartFlightRecording=duration=360s,filename=run_old_1.jfr -cp ../examples-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders -y $TEST_OPTS

echo "VM 2"
${JAVA_HOME_2}/bin/java ${ALL_OPTS} -XX:VitalsFile=vitals_new_1 -XX:StartFlightRecording=duration=360s,filename=run_new_1.jfr -cp ../examples-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders -y $TEST_OPTS



TEST_OPTS="--num-classes=3 --num-loaders=5000"

echo "VM 1"
${JAVA_HOME_1}/bin/java ${ALL_OPTS} -XX:VitalsFile=vitals_old_2 -XX:StartFlightRecording=duration=360s,filename=run_old_2.jfr -cp ../examples-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders -y $TEST_OPTS

echo "VM 2"
${JAVA_HOME_2}/bin/java ${ALL_OPTS} -XX:VitalsFile=vitals_new_2_balanced -XX:StartFlightRecording=duration=360s,filename=run_new_2_balanced.jfr -cp ../examples-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders -y $TEST_OPTS

echo "VM 2-aggressive"
${JAVA_HOME_2}/bin/java ${ALL_OPTS} -XX:VitalsFile=vitals_new_2_aggressive -XX:MetaspaceReclaimPolicy=aggressive -XX:StartFlightRecording=duration=360s,filename=run_new_2_aggressive.jfr -cp ../examples-1.0.jar de.stuefe.repros.metaspace.InterleavedLoaders -y $TEST_OPTS




