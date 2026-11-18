"""Optional full 1A proxy/twin control, using read-only objects from a supplied repo."""

import json
from pathlib import Path

from lint_common import git, revision, sources
from generate_zig017_baseline import generate
import zig017_lint as zig


def run(repo, ref, output):
    output.mkdir(parents=True, exist_ok=True)
    parent, head = revision(repo, "31796f5d093fce41446411c5c381b602c1c55757"), revision(repo, ref)
    baseline = output / "proxy-baseline.txt"
    baseline.write_text(generate(repo, parent, head), encoding="utf-8", newline="\n")
    _, rows = zig.read_baseline(baseline)
    positive = zig.check(repo, parent, head, baseline)
    assert not [r for r in positive if r[2] == "error"], positive
    path = "src/terminal/kitty/graphics_storage.zig"
    before, after = (sources(repo, rev, {path})[path] for rev in (parent, head))
    exact = '.data = try alloc.dupe(u8, "*" ** 64),'
    key = "**", exact
    assert zig.occurrences(before)[key] == zig.occurrences(after)[key] == 7

    # Write only to this fixture. The source repo's objects remain read-only.
    twin_repo = output / "twin-repo"
    twin_repo.mkdir()
    git(twin_repo, "init", "-q")
    git(twin_repo, "config", "user.name", "Lint Proxy Control")
    git(twin_repo, "config", "user.email", "lint@example.invalid")
    git(twin_repo, "config", "commit.gpgsign", "false")
    objects = git(repo, "rev-parse", "--path-format=absolute", "--git-path", "objects").decode().strip()
    (twin_repo / ".git/objects/info/alternates").write_text(
        objects.replace("\\", "/") + "\n", encoding="utf-8", newline="\n")
    addition = ('\ntest "lint extra repeat occurrence" {\n'
                '    const alloc = std.testing.allocator;\n'
                '    const copy = struct { data: []u8 }{\n'
                '        ' + exact + '\n'
                '    };\n    defer alloc.free(copy.data);\n}\n')
    twin_source = after + addition
    (output / "twin-graphics-storage.zig").write_text(twin_source, encoding="utf-8", newline="\n")
    # hash-object needs stdin, unlike the shared read-only git helper.
    import subprocess
    blob = subprocess.run(["git", "-C", str(twin_repo), "hash-object", "-w", "--stdin"],
                          input=twin_source.encode(), capture_output=True, check=True).stdout.decode().strip()
    git(twin_repo, "read-tree", head)
    git(twin_repo, "update-index", "--cacheinfo", "100644," + blob + "," + path)
    tree = git(twin_repo, "write-tree").decode().strip()
    twin = git(twin_repo, "commit-tree", tree, "-p", head, "-m", "lint duplicate control").decode().strip()
    negative = [r for r in zig.check(twin_repo, parent, twin, baseline) if r[2] == "error"]
    assert negative and all(r[0] == path and r[3] == "**" for r in negative), negative
    assert zig.occurrences(twin_source)[key] == 8
    report = dict(parent=parent, head=head, twin=twin, baseline_entries=len(rows),
                  baseline_allowance=sum(rows.values()), before=7, after=7, twin_count=8,
                  proxy_errors=0, twin_errors=negative)
    (output / "proxy-result.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(f"1A proxy: {len(rows)} baseline entries, {sum(rows.values())} allowances; "
          f"0 errors; duplicate twin rejected ({len(negative)} findings)")
    return report
