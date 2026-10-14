#!/bin/bash
# tailstat.sh <file.txt...>: n, >20, >30, >40, max, still from TAIL rows
for f in "$@"; do grep '^TAIL' "$f" | awk -v f=$(basename $f) '{d=$(NF-2); n++; if(d>20)a++; if(d>30)b++; if(d>40)c++; if(d>m)m=d; if($NF=="true")s++} END{printf "%-24s n %d >20 %d >30 %d >40 %d max %.1f still %d\n",f,n,a,b,c,m,s}'; done
