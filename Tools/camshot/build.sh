#!/bin/zsh
# Builds camshot.app into ~/dev/goxlr-re/build/camshot and signs it with the
# Apple Development identity, so the user's camera approval survives rebuilds.
# Use: build.sh, then
#   open -W -n --stdout <log> --stderr <log> ~/dev/goxlr-re/build/camshot/camshot.app --args capture <out.jpg> [...]
set -e
here=${0:A:h}
app=$HOME/dev/goxlr-re/build/camshot/camshot.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp $here/camshot-Info.plist $app/Contents/Info.plist
swiftc -O -o $app/Contents/MacOS/camshot $here/camshot.swift
identity=$(security find-identity -v -p codesigning | awk '/Apple Development/ {print $2; exit}')
codesign -f -s $identity $app
codesign --verify --strict $app
echo $app
