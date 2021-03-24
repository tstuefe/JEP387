set -e

echo "Running tests..."

VMNAME=""
VM=""

TEST_ROOT=$(pwd)
TEST_JDKS_DIR="${TEST_ROOT}/../test-jdks"

OTHER_OPTS=" -Xmx128M -Xms128M"
JFR_OPTS="-XX:StartFlightRecording=duration=10360s,filename=XXXX.jfr"
VITALS_OPTS="-XX:+UnlockDiagnosticVMOptions -XX:+DumpVitalsAtExit -XX:VitalsSampleInterval=1 -XX:VitalsFile=XXXX"
	
# $1 VM name
# $2 VM options
# $3 test name
# $4 test class and options
run_test() {

	local VMNAME=${1}
    	local JHOME=${TEST_JDKS_DIR}/${VMNAME}

	local UNIQUE_NAME="${VMNAME}-${3}"

	local VMOPTS="$2"
	local VMOPTS=${VMOPTS//XXXX/${UNIQUE_NAME}}

	local LOGFILE="out-${UNIQUE_NAME}.log"

 	${JHOME}/bin/java -version >$LOGFILE 2>&1

	COMMAND="${JHOME}/bin/java ${VMOPTS} -cp ${TEST_JDKS_DIR}/../examples/target/examples-1.0.jar ${4}" 
	echo "Running: ${COMMAND}"
	${COMMAND} >>$LOGFILE 2>&1 &

}

# $1 TEST NAME
# $2 test class and options
run_one_test_on_all_vms() {

	echo "Running $1..."

	mkdir -p $1
	pushd $1

	local ALL_VM_OPTS="$OTHER_OPTS $JFR_OPTS $VITALS_OPTS"

	run_test openjdk8-with-vitals "$ALL_VM_OPTS" "$1" "$2"

	run_test sapmachine11 "$ALL_VM_OPTS" "$1" "$2"

	run_test sapmachine15 "$ALL_VM_OPTS" "$1" "$2"

	run_test sapmachine16 "$ALL_VM_OPTS" "$1" "$2"

#	run_test sapmachine16 "$ALL_VM_OPTS -XX:MetaspaceReclaimPolicy=aggressive" "${1}-aggr" "$2"

    wait

	popd 

}

run_all_tests() {

	local SDATE=$(date -I)
	local I=0
        set +e
	while [ -d "./results/${SDATE}-${I}" ]; do
		let "I++"
	done
	set -e

	local RESULTS_DIR="./results/${SDATE}-${I}"
	mkdir -p $RESULTS_DIR

	pushd $RESULTS_DIR

	echo "Directory is $RESULTS_DIR"

	local TEST_CLASS="de.stuefe.repros.metaspace.InterleavedLoaders"
	local TEST_OPTIONS="-y --num-generations=10 --repeat-cycles=0 --class-size=10 --wiggle=0.2 --timefactor=1.0"

	# Elasticity
	local INTERLEAVES="1.0 0.1 0.01"
	for a in $INTERLEAVES; do
		run_one_test_on_all_vms "few-loaders-5-400-interleave${a}" "$TEST_CLASS $TEST_OPTIONS --num-loaders=5 --num-classes=400 --interleave=${a}"
	done

	# Effect of small loaders
	run_one_test_on_all_vms "many-loaders-250-8" "$TEST_CLASS $TEST_OPTIONS 	 --num-loaders=250 	    --num-classes=8 	--interleave=0.4"
	run_one_test_on_all_vms "many-loaders-500-4" "$TEST_CLASS $TEST_OPTIONS 	 --num-loaders=500	    --num-classes=4 	--interleave=0.4"
	run_one_test_on_all_vms "many-loaders-1000-2" "$TEST_CLASS $TEST_OPTIONS 	 --num-loaders=1000 	    --num-classes=2 	--interleave=0.4"


	popd

	echo "Done."
}

run_all_tests

