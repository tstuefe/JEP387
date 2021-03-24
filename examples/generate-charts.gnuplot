set encoding utf8

# See https://github.com/Gnuplotting/gnuplot-palettes
# line styles from rdylbu
set style line 1 lt 1 lc rgb '#D73027' # red
set style line 2 lt 1 lc rgb '#F46D43' # orange
set style line 3 lt 1 lc rgb '#FDAE61' # 
set style line 4 lt 1 lc rgb '#FEE090' # pale orange
set style line 5 lt 1 lc rgb '#E0F3F8' # pale blue
set style line 6 lt 1 lc rgb '#ABD9E9' # 
set style line 7 lt 1 lc rgb '#74ADD1' # medium blue
set style line 8 lt 1 lc rgb '#4575B4' # blue

# Palette
set palette maxcolors 8
set palette defined ( 0 '#E41A1C', 1 '#377EB8', 2 '#4DAF4A', 3 '#984EA3',\
4 '#FF7F00', 5 '#FFFF33', 6 '#A65628', 7 '#F781BF' )

# Standard border
set style line 11 lc rgb '#808080' lt 1 lw 3
set border 0 back ls 11
set tics out nomirror

# Standard grid
set style line 12 lc rgb '#c0c0c0' lt 0 lw 1
set grid back ls 12
#unset grid

########################################

set datafile separator ','
CSV_FILE=TESTDIR."/ALL.csv"

set key autotitle columnhead inside # use the first line as title
set ylabel "Megabyte" # label for the Y axis
set xlabel 'Seconds' # label for the X axis

#kbyte to mbyte
k2m(x)=x/1024

set terminal svg enhanced size 500,500 font "FreeSerif, 14"

set xrange [0:SCALEX]

# We unify y scale for metaspace values
set yrange [0:SCALEY/1024]

#########################################

set title "Metaspace, committed, JDK 15 vs 16"
set output TESTDIR."/metaspace-committed-comparisions-15-16.svg"

plot CSV_FILE using 0:(k2m($8)) with lines ls 3 title "JDK-15", \
            '' using 0:(k2m($11)) with lines ls 6 title "JDK-16", \
            '' using 0:(k2m($14)) with lines ls 8 title "JDK-16 aggr", \

#########################################

set title "Metaspace, committed, JDK 8 to 16"
set output TESTDIR."/metaspace-committed-comparisions-8-to-16.svg"

plot CSV_FILE using 0:(k2m($2)) with lines ls 1 title "JDK-8", \
            '' using 0:(k2m($5)) with lines ls 2 title "JDK-11", \
            '' using 0:(k2m($8)) with lines ls 3 title "JDK-15", \
            '' using 0:(k2m($11)) with lines ls 6 title "JDK-16", \
            '' using 0:(k2m($14)) with lines ls 8 title "JDK-16 aggr", \

#########################################

set title "JDK-8, Metaspace, committed vs used"
set output TESTDIR."/jdk8-metaspace-comm-vs-used.svg"

plot CSV_FILE using 0:(k2m($2)) with lines ls 3 title "committed", \
            '' using 0:(k2m($1)) with lines ls 2 title "used"

#########################################

set title "JDK-11, Metaspace, committed vs used"
set output TESTDIR."/jdk11-metaspace-comm-vs-used.svg"

plot CSV_FILE using 0:(k2m($5)) with lines ls 3 title "committed", \
            '' using 0:(k2m($4)) with lines ls 2 title "used"

#########################################

set title "JDK-15, Metaspace, committed vs used"
set output TESTDIR."/jdk15-metaspace-comm-vs-used.svg"

plot CSV_FILE using 0:(k2m($8)) with lines ls 3 title "committed", \
            '' using 0:(k2m($7)) with lines ls 2 title "used"

#########################################

set title "JDK-16, Metaspace, committed vs used"
set output TESTDIR."/jdk16-metaspace-comm-vs-used.svg"

plot CSV_FILE using 0:(k2m($11)) with lines ls 3 title "committed", \
            '' using 0:(k2m($10)) with lines ls 2 title "used"


#########################################

set title "JDK-16 /w aggressive reclaim, Metaspace committed vs used"
set output TESTDIR."/jdk16-aggr-metaspace-comm-vs-used.svg"

plot CSV_FILE using 0:(k2m($14)) with lines ls 3 title "committed", \
            '' using 0:(k2m($13)) with lines ls 2 title "used"

########################################

set title "RSS, JDK 15 vs 16"
set output TESTDIR."/rss-comparisions-15-vs-16.svg"
unset yrange

plot CSV_FILE using 0:(k2m($9)) with lines ls 3 title "JDK-15", \
            '' using 0:(k2m($12)) with lines ls 6 title "JDK-16", \
            '' using 0:(k2m($15)) with lines ls 8 title "JDK-16 aggr", \

########################################

set title "RSS, JDK 8 to 16"
set output TESTDIR."/rss-comparisions-8-to-16.svg"
unset yrange

plot CSV_FILE using 0:(k2m($3)) with lines ls 1 title "JDK-8", \
            '' using 0:(k2m($6)) with lines ls 2 title "JDK-11", \
            '' using 0:(k2m($9)) with lines ls 3  title "JDK-15", \
            '' using 0:(k2m($12)) with lines ls 6 title "JDK-16", \
            '' using 0:(k2m($15)) with lines ls 8 title "JDK-16 aggr", \

