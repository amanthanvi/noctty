#!/bin/bash
# Measurement build (measure AUMID, ReleaseFast, version 0.0.1) of a source revision of wt-tabline.
# Usage: buildvariant.sh <out-name> <rev|HEAD> <win10:0|1>
# Builds in the wt-tabline checkout (shared cache) and always restores src to HEAD.
set -u
W=/c/Users/amant/.t3/worktrees/winghostty
OUT=$W/_tl/$1
cd $W/wt-tabline
git diff --quiet HEAD -- src || { echo "src dirty; refusing"; exit 1; }
if [ "$2" != HEAD ]; then git checkout "$2" -- src || exit 1; fi
python -I $W/_scratch-pkg37/apply_aumid_isolate.py $W/wt-tabline || { git checkout HEAD -- src; exit 1; }
if [ "$3" = 1 ]; then
  python -I - <<'EOF'
import pathlib
p = pathlib.Path("src/apprt/win32/app.zig")
s = p.read_text(encoding="utf-8")
old = "self.os_build = probeWindowsBuild();"
assert s.count(old) == 1
p.write_text(s.replace(old, "self.os_build = 19045; // MEASUREMENT ONLY: force the Windows 10 branch"), encoding="utf-8")
print("forced os_build 19045")
EOF
fi
echo "$1 rev=$2 win10=$3 head=$(git rev-parse --short HEAD) start $(date -u +%FT%TZ)"
cmd //c "start /belownormal /wait /b scripts\\dev-windows.cmd zig build -Doptimize=ReleaseFast -Dversion-string=0.0.1 -p $(cygpath -w $OUT) --summary none" < /dev/null > $W/_tl/build-$1.log 2>&1
rc=$?
git checkout HEAD -- src
git diff --quiet HEAD -- src && echo "src restored" || echo "SRC RESTORE FAILED"
echo "$1 exit $rc $(date -u +%FT%TZ) measure16=$(grep -c -a -P 'y\x00\.\x00m\x00e\x00a\x00s\x00u\x00r\x00e\x00' $OUT/bin/noctty.exe)"
