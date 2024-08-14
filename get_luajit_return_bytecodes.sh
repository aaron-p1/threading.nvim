#!/usr/bin/env bash

set -euo pipefail

# This script is used to get the bytecodes of return statements from the luajit source code.
# Used in lua/threading/util.lua `return_bytecodes`
# https://github.com/LuaJIT/LuaJIT/blob/v2.1/src/lj_bc.h#L165

url_prefix="https://raw.githubusercontent.com/LuaJIT/LuaJIT/"
url_suffix="/src/lj_bc.h"

declare -A version_bc_names

# RET0 is not included because returning nil is ok
version_bc_names[v2.1]="RET RETM RET1 CALLMT CALLT"

default_tag="v2.1"

tag=${1:-$default_tag}

url="$url_prefix$tag$url_suffix"
bc_names=${version_bc_names[$tag]}

echo "Getting bytecodes from version $tag ($url)"

tmpfile=$(mktemp)
trap 'rm "$tmpfile"' EXIT

curl -s "$url" | grep -Pzo "#define BCDEF\\((.|\n)*?[^\\\\]\n" > "$tmpfile"

declare -A bc_bytes
count=0

while read -r line; do
  # if not starts with _ continue
  if [[ ! "$line" =~ ^_ ]]; then
    continue
  fi

  # check for each bc_name if (bc_name,
  for bc_name in $bc_names; do
    if [[ "$line" =~ $bc_name, ]]; then
      # byte name is \num, num is 3 chars
      bc_bytes[$bc_name]=$(printf "\%03d" $count)
    fi
  done

  count=$((count + 1))
done < "$tmpfile"

echo "Bytecodes with names"
for bc_name in $bc_names; do
  echo "$bc_name: ${bc_bytes[$bc_name]}"
done

echo

echo "Lua table:"
echo "{"
for bc_name in $bc_names; do
  echo "  \"\\000${bc_bytes[$bc_name]}\", -- $bc_name"
done
echo "}"
