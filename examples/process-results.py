import csv
import os
import subprocess
import argparse
import sys
import pathlib


def trc(text):
    print("--- " + text)


def error_exit(text):
    print('*** ERROR: ' + text)
    sys.exit(':-(')


def verbose(text):
    if args.is_verbose:
        print("--- " + text)


def has_extension(filename, extensions):
    extension = pathlib.Path(filename).suffix
    if extension in extensions:
        return True
    else:
        return False


def is_csv_file(filename):
    return has_extension(filename, {".csv"})

def run_command_and_return_stdout(command):
    verbose('calling: ' + ' '.join(command))
    try:
        stdout = subprocess.check_output(command)
    except subprocess.CalledProcessError as e:
        trc('Command failed ' + ' '.join(command))
        print(e)
        sys.exit('Sowwy :-(')
    stdout = stdout.decode("utf-8")
    verbose('out: ' + stdout)
    return stdout

def nearest_upper_ceiling(v, inc):
    v2 = inc
    while v2 < v:
        v2 += inc
    return v2

# ---------------------------

parser = argparse.ArgumentParser(description='Assemble processed csv.')

parser.add_argument("-v", "--verbose", dest="is_verbose", default=False,
                    help="Debug output", action="store_true")

parser.add_argument("--dry-run", dest="dry_run", default=False, action="store_true",
                    help="Squawk but don't leap.")

# positional args
parser.add_argument("directories", default=[], nargs='+', metavar="FILES",
                    help="Directories containing test run results")

args = parser.parse_args()
if args.is_verbose:
    trc(str(args))

for d in args.directories:

    D = pathlib.Path(d)
    if not D.exists:
        error_exit("Directory not found: " + d)

    trc("Processing " + str(D.absolute()) + "...")

    # Find csv files in dir
    csv_files = sorted(D.glob("*.csv"))
    verbose("Found CSV files: " + str(csv_files))

    # ordered:
    # 0 - openjdk8
    # 1 - jdk11
    # 2 - jdk15
    # 3 - jdk16
    # 4 - jdk16 aggressive mode
    # (untested vms are left as None)
    csv_files_ordered = [None, None, None, None, None]

    for f in csv_files:
        if "sanitized" in f.name:
            continue
        if f.name.startswith("openjdk8"):
            csv_files_ordered[0] = f
        elif f.name.startswith("sapmachine11"):
            csv_files_ordered[1] = f
        elif f.name.startswith("sapmachine15"):
            csv_files_ordered[2] = f
        elif f.name.startswith("sapmachine16") and "aggr" not in f.name:
            csv_files_ordered[3] = f
        elif f.name.startswith("sapmachine16") and "aggr" in f.name:
            csv_files_ordered[4] = f

    verbose(str(csv_files_ordered))

    # First generate sanitized versions of the Vitals:
    # - remove headers
    # - remove empty lines
    # - only keep the first (short term) section
    # When doing this, we also measure the number of entries in the short term section
    entries_in_short_term_section = 0
    for i in range(len(csv_files_ordered)):
        f = csv_files_ordered[i]
        if f is None:
            continue
        entries_in_this_file = 0
        trc("Sanitizing " + f.name + "...")
        f_sanitized = D.joinpath(f.name.replace(".csv", "-sanitized.csv"))
        with open(f_sanitized, "w") as f2_w:
            with open(f, "r") as f2_r:
                for line in f2_r:
                    line = line.strip()
                    if line == "" or \
                            line.startswith("Vitals:") or \
                            line.startswith("Short Term Values:") or \
                            line.startswith("#"):
                        continue
                    if line.startswith("Mid Term Values:"):
                        break
                    f2_w.write(line + "\n")
                    entries_in_this_file += 1
        # replace f with its sanitized version
        csv_files_ordered[i] = f_sanitized
        if entries_in_short_term_section < entries_in_this_file:
            entries_in_short_term_section = entries_in_this_file


    # Now build up the assembled CSV
    result_csv_header = [
        "JDK-8 Metaspace Used",             # 0
        "JDK-8 Metaspace Committed",        # 1
        "JDK-8 RSS",                        # 2
        "JDK-11 Metaspace Used",            # 3
        "JDK-11 Metaspace Committed",       # 4
        "JDK-11 RSS",                       # 5
        "JDK-15 Metaspace Used",            # 6
        "JDK-15 Metaspace Committed",       # 7
        "JDK-15 RSS",                       # 8
        "JDK-16 Metaspace Used",            # 9
        "JDK-16 Metaspace Committed",       # 10
        "JDK-16 RSS",                       # 11
        "JDK-16-aggr Metaspace Used",       # 12
        "JDK-16-aggr Metaspace Committed",  # 13
        "JDK-16-aggr RSS",                  # 14
    ]

    # pre-build a two dimensional array and fill it with 0. Width is the number of columns (see above),
    # height the number of results we found, plus some for trailing 0.
    expected_result_number = entries_in_short_term_section + 10
    results = [[0 for x in range(len(result_csv_header))] for y in range(expected_result_number)]

    highest_memory_value = 0
    for f in csv_files_ordered:
        if f is None:
            continue
        trc("Processing " + str(f.absolute()) + "...")

        with open(f, newline='') as f2:
            csvreader = csv.reader(f2, delimiter=',', quotechar='"')
            headers = next(csvreader)

            # find out source and target indices of the columns we want to extract
            meta_comm_sourceindex = -1
            meta_used_sourceindex = -1
            rss_sourceindex = -1

            # find out source index
            for i in range(len(headers)):
                column_header = headers[i]
                if column_header.endswith("meta-comm"):
                    meta_comm_sourceindex = i
                elif column_header.endswith("meta-used"):
                    meta_used_sourceindex = i
                elif column_header.endswith("rss-all"):
                    rss_sourceindex = i

            if meta_comm_sourceindex == -1 or meta_used_sourceindex == -1 or rss_sourceindex == -1:
                trc(str(headers))
                error_exit("columns missing")

            # find out target index
            # (we know the files are in the order of: jdk8,11,15,16,16aggr, with None representing VMs we have not tested)
            meta_used_targetindex = csv_files_ordered.index(f) * 3
            meta_comm_targetindex = meta_used_targetindex + 1
            rss_targetindex = meta_comm_targetindex + 1

            # now read data, and transform them. We also keep track of the highest values to be
            # able to scale x and y nicely
            target_row_index = 0
            for sourcerow in csvreader:
                target_row = results[target_row_index]

                meta_comm = int(sourcerow[meta_comm_sourceindex])
                if highest_memory_value < meta_comm:
                    highest_memory_value = meta_comm
                target_row[meta_comm_targetindex] = meta_comm

                meta_used = int(sourcerow[meta_used_sourceindex])
                if highest_memory_value < meta_used:
                    highest_memory_value = meta_used
                target_row[meta_used_targetindex] = meta_used

                rss = int(sourcerow[rss_sourceindex])
              #  if highest_memory_value < rss:
              #      highest_memory_value = rss
                target_row[rss_targetindex] = rss

                target_row_index += 1

    processed_cvs = D.joinpath("ALL.csv")
    with open(processed_cvs, "w") as f2:
        csvwriter = csv.writer(f2, delimiter=',')
        csvwriter.writerow(result_csv_header)
        for row in results:
            csvwriter.writerow(row)

    # Plotting

    # The scale of the y axis should be rounded up to the next 200 m
    # (Note: kb)
    if (highest_memory_value < 400 * 1024):
        algn = 1024 * 100
    else:
        algn = 1024 * 200
    scale_y = nearest_upper_ceiling(highest_memory_value, algn)
    #scale_y += algn

    # scale of x axis is number of expected values
    scale_x = expected_result_number

    verbose("highest value " + str(highest_memory_value))
    verbose("expected_result_number " + str(expected_result_number))

    run_command_and_return_stdout(['gnuplot', 
                                    '-e', 'TESTDIR=\'' + str(D.absolute()) + '\'',
                                    '-e', 'SCALEX=' + str(scale_x),
                                    '-e', 'SCALEY=' + str(scale_y),
                                    '-p', 'generate-charts.gnuplot'])









