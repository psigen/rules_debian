DEB_ARCHIVE_BUILDFILE = """
cc_library
"""

def get_package_sha256(ctx, package_name, package_version = None):
    """
    Get the SHA256 hash for a given package.

    Args:
      ctx: Repository rule context in which to execute commands
      package_name: name of the ubuntu package to query
      package_version: optional specific version string of the package to retrieve

    Returns:
      The SHA256 string of the package as stored in apt-cache
    """
    package_query = package_name if not package_version else "%s=%s".format(package_name, package_version)

    # Use APT tooling to fetch a list of installation URIs.
    ctx.report_progress("Fetching cache information for {}".format(package_name))
    cache_result = ctx.execute(
        ["apt-cache", "show", "--no-all-versions", package_query],
    )
    if cache_result.return_code:
        fail("Unable to retrieve package SHA256 for {}".format(package_name))

    for line in cache_result.stdout.splitlines():
        if line.startswith("SHA256"):
            return line.split(" ")[1]

    fail("Unable to find a package SHA256 for {}".format(package_name))

def _deb_archive_impl(ctx):
    # Compile the full list of packages that need to be retrieved.
    # For each package, assemble a dependency tree of some kind.
    # Convert each package into a repository rule?
    # Export cc_library for each package.

    # Create a header for the buildfile.
    # Other content will be appended to this from the individual packages.
    buildfile = """
    # Buildfile for '{name}' deb_archive.
    """.format(name = ctx.name)

    # Create repository rules for each package.
    for package_name, package_version in ctx.attr.packages.items():
        # TODO: convert package version.
        if package_version == "*":
            package_version = None
        package_sha256 = get_package_sha256(ctx, package_name, package_version)

        # Use APT tooling to fetch a list of installation URIs.
        ctx.report_progress("Fetch URI for {}".format(package_name))
        uri_result = ctx.execute(
            ["apt-get", "-qq", "install", "--reinstall", "--print-uris", package_name],
        )
        if uri_result.return_code:
            fail("Unable to resolve package URI for '{}'".format(package_name))

        # Extract a list of URIs from the result.
        uris = [uri.split(" ")[0].replace("'", "") for uri in uri_result.stdout.splitlines()]

        for uri in uris:
            package_deb = "{}.deb".format(package_name)
            print("Downloading '{}' from URI: {}".format(package_deb, uri))

            download_result = ctx.download(uri, package_deb, sha256 = package_sha256)
            if not download_result.success:
                fail("Failed to download deb '{}'".format(package_deb))

            unpack_result = ctx.execute(
                ["ar", "x", package_deb, "data.tar.xz"],
            )
            if unpack_result.return_code:
                fail("Unable to unpack 'data.tar.xz' from deb '{}'".format(package_deb))

            extract_result = ctx.extract("data.tar.xz", output = "", stripPrefix = "")

        # Add the content of these packages to a library directive.
        buildfile += """
cc_library(
    name = "{package_name}",
    hdrs = glob(["usr/include/**/*"]),
    srcs = glob(["usr/lib/**/*"]),
    visibility = ["//visibility:public"],
)
        """.format(package_name = package_name)

        # Create the final buildfile including all the aggregated package rules.
        ctx.file("BUILD", buildfile)

deb_archive = repository_rule(
    implementation = _deb_archive_impl,
    attrs = {
        "packages": attr.string_dict(
            mandatory = True,
            doc = "List of debian packages and versions to use",
        ),
        "strict_visibility": attr.bool(default = False),
    },
    doc = "Makes available a set of debian packages for use in builds.",
)

def _deb_package_impl(ctx):
    """
    Make a single deb package available from an APT repository.
    """
    package = ctx.attr.package
    package_sha256 = get_package_sha256(ctx, package)

    # Use APT tooling to fetch a list of installation URIs.
    ctx.report_progress("Fetching URI for %s" % package)
    uri_result = ctx.execute(
        ["apt-get", "-qq", "install", "--reinstall", "--print-uris", package],
    )
    if uri_result.return_code:
        fail("Unable to resolve package URI for %s" % package)

    # Extract just a list of URIs and from the result.
    uris = [uri.split(" ")[0].replace("'", "") for uri in uri_result.stdout.splitlines()]
    print(uris)

    for uri in uris:
        ctx.download(uri, package, sha256 = package_sha256)

deb_package = repository_rule(
    implementation = _deb_package_impl,
    attrs = {
        "md5sum": attr.string(default = ""),
    },
    doc = "Make available a single debian package.",
)
