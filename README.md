# rules_debian

Bazel rules to manage installation and integration of `.deb` archives from
Debian APT repositories.

## Quick Start

**In your `WORKSPACE`**

```
git_repository(
    name = "rules_debian",
    remote = "https://github.com/psigen/rules_debian.git"
    tag = "master"  # Replace this with 'commit = <git hash>' after testing.
)

load("@rules_debian//:debian.bzl", "deb_archive")

deb_archive(
    name = "org_boost",
    packages = {
        "libboost-system-dev": "*",
    },
    export_cc = True,
)
```

**In your `BUILD.bazel`**

```
cc_library(
    name = "example",
    srcs = ["example.cpp"],
    deps = [
        "@org_boost//libboost-system-dev:cc",
    ],
)
```
