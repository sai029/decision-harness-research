#!/bin/bash
# usage: run_extract.sh <variant: A|N|C> <thread: t1..t8>
v=$1; t=$2
cd "$(dirname "$0")"
{ cat p$v.txt; echo; echo "--- スレッド（データ）ここから ---"; cat $t.txt; echo "--- ここまで ---"; } | claude -p --model sonnet --tools "" > out/${v}_${t}.json 2> out/${v}_${t}.err
