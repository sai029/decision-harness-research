#!/bin/bash
cd "$(dirname "$0")"
python -I mk_s2.py A $1 | claude -p --model sonnet --tools "" > out/S2_$1.json 2> out/S2_$1.err
