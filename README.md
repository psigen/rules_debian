# rules_debian

Bazel rules to manage installation and integration of `.deb` archives from
Debian APT repositories.

Note: It isn't necessary to create a mapping for debian packages since all
allowable package names fall into a subset of allowable bazel target names:

- https://docs.bazel.build/versions/master/build-ref.html#lexi
- https://www.debian.org/doc/manuals/debian-reference/ch02.en.html#_debian_package_file_names

## Repository rules

- [deb_archive](#deb_archive)
- [deb_package](#deb_package)
- [deb_packages](#deb_packages)

Check out some [examples](./examples).

## deb_archive

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

## deb_package

**In your `WORKSPACE`**

```
git_repository(
    name = "rules_debian",
    remote = "https://github.com/psigen/rules_debian.git"
    tag = "master"  # Replace this with 'commit = <git hash>' after testing.
)

load("@rules_debian//:debian.bzl", "deb_package")

deb_package(
    name = "boost-dev",
    sha256 = "bec8082fb8e219d54676d59f0ad468452f2d63f01878acb2fe7228085b33c011",
    urls = [
        "http://us.archive.ubuntu.com/ubuntu/pool/main/b/boost1.65.1/libboost1.65-dev_1.65.1+dfsg-0ubuntu5_amd64.deb",
    ],
    export_cc = True,
)

deb_package(
    name = "boost-system",
    sha256 = "390e93c275504a03101de7e35d898f224dff2594ff802dcc83a936b5fca690cc",
    urls = [
        "http://us.archive.ubuntu.com/ubuntu/pool/main/b/boost1.65.1/libboost-system1.65.1_1.65.1+dfsg-0ubuntu5_amd64.deb",
    ],
    export_cc = True,
)

```

**In your `BUILD.bazel`**

```
cc_library(
    name = "example",
    srcs = ["example.cpp"],
    deps = [
        "@boost-dev//:cc",
        "@boost-system//:cc",
    ],
)
```

## deb_packages

**In your `WORKSPACE`**

```
deb_packages(
    name = "boost",
    dist = "bionic",
    mirrors = ["http://us.archive.ubuntu.com/ubuntu/"],
    packages = {
        "libboost1.65-dev": "bec8082fb8e219d54676d59f0ad468452f2d63f01878acb2fe7228085b33c011",
        "libboost-system1.65-dev": "98f7a2a1d44a346249c4398e1e2fa37656c83651aaabc6e81aad416339b37a9c",
        "libboost-system1.65.1": "390e93c275504a03101de7e35d898f224dff2594ff802dcc83a936b5fca690cc",
    },
)
```

**In your `BUILD.bazel`**

```
cc_binary(
    name = "example",
    srcs = ["example.cpp"],
    deps = [
        "@boost//libboost-system1.65-dev:cc",
    ],
)
```
