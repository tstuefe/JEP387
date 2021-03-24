set encoding utf8

# See https://github.com/Gnuplotting/gnuplot-palettes
# line styles from ylorrd
# line styles
set style line 1 lw 1 lt 1 lc rgb '#FFFFCC' # very light yellow-orange-red
set style line 2 lw 1 lt 1 lc rgb '#FFEDA0' # 
set style line 3 lw 1 lt 1 lc rgb '#FED976' # light yellow-orange-red
set style line 4 lw 1 lt 1 lc rgb '#FEB24C' # 
set style line 5 lw 1 lt 1 lc rgb '#FD8D3C' # 
set style line 6 lw 1 lt 1 lc rgb '#FC4E2A' # medium yellow-orange-red
set style line 7 lw 1 lt 1 lc rgb '#E31A1C' #
set style line 8 lw 1 lt 1 lc rgb '#B10026' # dark yellow-orange-red

# greys
set style line 101 lt 1 lc rgb '#FFFFFF' # white
set style line 102 lt 1 lc rgb '#F0F0F0' # 
set style line 103 lt 1 lc rgb '#D9D9D9' # 
set style line 104 lt 1 lc rgb '#BDBDBD' # light grey
set style line 105 lt 1 lc rgb '#969696' # 
set style line 106 lt 1 lc rgb '#737373' # medium grey
set style line 107 lt 1 lc rgb '#525252' #
set style line 108 lt 1 lc rgb '#252525' # dark grey

# blues
set style line 201 lt 1 lc rgb '#F7FBFF' # very light blue
set style line 202 lt 1 lc rgb '#DEEBF7' # 
set style line 203 lt 1 lc rgb '#C6DBEF' # 
set style line 204 lt 1 lc rgb '#9ECAE1' # light blue
set style line 205 lt 1 lc rgb '#6BAED6' # 
set style line 206 lt 1 lc rgb '#4292C6' # medium blue
set style line 207 lt 1 lc rgb '#2171B5' #
set style line 208 lt 1 lc rgb '#084594' # dark blue

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

PNGFONT="FreeSerif, 12"
SVGFONT="FreeSerif, 14"

set xrange [0:150]

########################################

set datafile separator ','

set key autotitle columnhead inside opaque # use the first line as title
#set key autotitle columnhead outside opaque # use the first line as title
set ylabel "Megabyte" # label for the Y axis
set xlabel 'Seconds' # label for the X axis

#kbyte to mbyte
k2m(x)=x/1024

#set terminal svg enhanced size 500,500 font "Rock Salt, 14"

#        "used metaspace",             		    # 1
#        "committed fragmentation 1.0",        # 2
#        "committed fragmentation 0.1",        # 2
#        "committed fragmentation 0.01",       # 2

#########################################

#CSV_FILE="JDK11-committed-metaspace-by-fragmentation/JDK11-committed-metaspace-by-fragmentation.csv"
#set yrange [0:300]
#
#set terminal svg enhanced size 800,500 font SVGFONT
#set title "JDK 11, Committed Metaspace by Fragmentation"
#set output "jdk11-committed-metaspace-by-fragmentation.svg"
#
#plot CSV_FILE \
#               using 0:(k2m($4)) with lines ls 6 title "committed, moderate frag", \
#            '' using 0:(k2m($3)) with lines ls 5 title "committed, light frag", \
#            '' using 0:(k2m($2)) with lines ls 4 title "committed, no frag", \
#            '' using 0:(k2m($1)) with lines ls 103 title "used", \
#
#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output "jdk11-committed-metaspace-by-fragmentation.png"
#replot
#

set terminal svg enhanced size 600,500 font SVGFONT
#########################################

CSV_FILE="JDK15-committed-metaspace-by-fragmentation/JDK15-committed-metaspace-by-fragmentation.csv"
set yrange [0:350]
set title "JDK 15, Committed Metaspace by Fragmentation"
set output "jdk15-committed-metaspace-by-fragmentation.svg"

plot CSV_FILE \
               using 0:(k2m($1)) with filledcurve x ls 102 title "used", \
            '' using 0:(k2m($2)) with lines ls 4 title "no frag", \
            '' using 0:(k2m($3)) with lines ls 6 title "light frag", \
            '' using 0:(k2m($4)) with lines ls 8 title "moderate frag", \

#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output "jdk15-committed-metaspace-by-fragmentation.png"
#replot

#########################################

CSV_FILE="JDK16-committed-metaspace-by-fragmentation/JDK16-committed-metaspace-by-fragmentation.csv"
set title "JDK 16, Committed Metaspace by Fragmentation"
set output "jdk16-committed-metaspace-by-fragmentation.svg"

plot CSV_FILE \
               using 0:(k2m($1)) with filledcurve x ls 102 title "used", \
            '' using 0:(k2m($2)) with lines ls 204 title "no frag", \
            '' using 0:(k2m($3)) with lines ls 206 title "light frag", \
            '' using 0:(k2m($4)) with lines ls 208 title "moderate frag", \

#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output "jdk16-committed-metaspace-by-fragmentation.png"
#replot

#############################################################

# medium vs moderate frag for both 15 and 16

CSV_FILE="JDK15-vs-16-committed-metaspace-by-fragmentation/JDK15-vs-16-committed-metaspace-by-fragmentation.csv"
set title "JDK 15 vs 16, Committed Metaspace by Fragmentation"
set output "jdk15-vs-16-committed-metaspace-by-fragmentation.svg"

# 1: used
# 2 jdk15 med frag
# 3 jdk15 moderate frag
# 4 jdk16 med frag
# 5 jdk16 moderate frag

plot CSV_FILE \
               using 0:(k2m($2)) with lines ls 5 title "15, light frag", \
            '' using 0:(k2m($3)) with lines ls 8 title "15, moderate frag", \
            '' using 0:(k2m($4)) with lines ls 205 title "16, light frag", \
            '' using 0:(k2m($5)) with lines ls 208 title "16, moderate frag", \

#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output "jdk15-vs-16-committed-metaspace-by-fragmentation.png"
#replot



#############################################################

# committed metaspace by loader granularity

# 1: used
# 2 250-8
# 3 500-4
# 4 1000-2

CSV_FILE="JDK15-committed-metaspace-by-loader-granularity/JDK15-committed-metaspace-by-loader-granularity.csv"
set yrange [0:1000]

OUTPUT_STEM="jdk15-committed-metaspace-by-loader-granularity"

set title "JDK 15, Committed Metaspace by Loader Granularity"
set output OUTPUT_STEM.".svg"

plot CSV_FILE \
               using 0:(k2m($1)) with filledcurve x ls 102 title "used", \
            '' using 0:(k2m($2)) with lines ls 5 title "250-8", \
            '' using 0:(k2m($4)) with lines ls 8 title "1000-2", \

#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output OUTPUT_STEM.".png"
#replot

CSV_FILE="JDK16-committed-metaspace-by-loader-granularity/JDK16-committed-metaspace-by-loader-granularity.csv"
set yrange [0:1000]

OUTPUT_STEM="jdk16-committed-metaspace-by-loader-granularity"

set title "JDK 16, Committed Metaspace by Loader Granularity"
set output OUTPUT_STEM.".svg"

plot CSV_FILE \
               using 0:(k2m($1)) with filledcurve x ls 102 title "used", \
            '' using 0:(k2m($2)) with lines ls 205 title "250-8", \
            '' using 0:(k2m($4)) with lines ls 208 title "1000-2", \

#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output OUTPUT_STEM.".png"
#replot

#############################################################

# JDK15 vs 16 by loader granularity

CSV_FILE="JDK15-vs-16-committed-metaspace-by-loader-granularity/JDK15-vs-16-committed-metaspace-by-loader-granularity.csv"
set yrange [0:1000]

OUTPUT_STEM="jdk15-vs-16-committed-metaspace-by-loader-granularity"

set title "JDK 15 vs 16, Committed Metaspace by Loader Granularity"
set output OUTPUT_STEM.".svg"

# 1: used
# 2 jdk15 250-8
# 3 jdk15 1000-2
# 4 jdk16 250-8
# 5 jdk16 1000-2

plot CSV_FILE \
               using 0:(k2m($2)) with lines ls 5 title "JDK-15, 250-8", \
            '' using 0:(k2m($3)) with lines ls 8 title "JDK-15, 1000-2", \
            '' using 0:(k2m($4)) with lines ls 205 title "JDK-16, 250-8", \
            '' using 0:(k2m($5)) with lines ls 208 title "JDK-16, 1000-2", \

#set terminal pngcairo enhanced size 800,500 font PNGFONT
#set output OUTPUT_STEM.".png"
#replot

