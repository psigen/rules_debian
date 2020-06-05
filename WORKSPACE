workspace(name = "com_github_psigen")

#load("@bazel_tools//tools/build_defs/repo:http.bzl", "http_archive")
#
#http_archive(
#    name = "libboost-dev",
#    build_file_content = """
#    cc_library()
#    """,
#    sha256 = "8a7cacac27ccd3d1249cd815edc34f8765a3ab0c6d60df432ba4ab52f23fdec9",
#    type = "tar",
#    urls = ["http://us.archive.ubuntu.com/ubuntu/pool/main/b/boost-defaults/libboost-dev_1.65.1.0ubuntu1_amd64.deb"],
#)

load("//:debian.bzl", "deb_archive")

deb_archive(
    name = "org_boost",
    packages = {
        "libboost-dev": "*",
    },
)
