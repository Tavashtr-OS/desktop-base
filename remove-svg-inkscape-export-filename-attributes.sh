#!/bin/bash

set -e

for f in $(grep -Rl --include \*.svg inkscape:export-filename); do
  xmlstarlet ed -L -d '/svg/@inkscape:export-filename' "${f}"
done
