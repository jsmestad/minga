#!/usr/bin/env python3
"""Write fixture Linux release assets, under their release names, for the repository end-to-end check.

Usage: package_repo_fixtures.py OUTPUT VERSION

Each fixture release's `minga` prints `minga VERSION`, so installed packages pass
the same `minga --version` check as real ones. Requires dpkg-deb and rpmbuild.
"""

from pathlib import Path
import shutil
import sys

from build_tui_packages_test import BuildTuiPackagesTest


def main():
    output, version = Path(sys.argv[1]), sys.argv[2]
    output.mkdir(parents=True, exist_ok=True)
    for arch in ("x86_64", "aarch64"):
        case = BuildTuiPackagesTest("test_rolling_versions_sort_before_the_stable_release")
        case.setUp()
        try:
            case.make_fixture(arch, version=version)
            case.put("bin/minga", f"#!/bin/sh\necho 'minga {version}'\n".encode(), mode=0o755)
            case.pack()
            for path in case.build(arch=arch, version=version, output=case.root / "packages"):
                shutil.copy(path, output)
            shutil.copy(case.archive, output / f"minga_{version}_linux_{arch}.tar.gz")
        finally:
            case.doCleanups()


if __name__ == "__main__":
    main()
