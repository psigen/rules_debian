"""
Repository rules for interacting with debian repositories.
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
    package_query = package_name if not package_version else "{}={}".format(package_name, package_version)

    # Use APT tooling to fetch a list of installation URIs.
    ctx.report_progress("Fetching cache information for {}".format(package_query))
    cache_result = ctx.execute(
        ["apt-cache", "show", "--no-all-versions", package_query],
    )
    if cache_result.return_code:
        fail("Unable to retrieve package SHA256 for {}".format(package_query))

    for line in cache_result.stdout.splitlines():
        if line.startswith("SHA256"):
            return line.split(" ")[1]

    fail("Unable to find a package SHA256 for {}".format(package_query))

def compute_package_dependency_tree(ctx, packages):
    """
    Computes a dependency tree starting with the specified packages.

    This uses APT to come up with the dependency hierarchy for the set of packages.
    If no version is specified, APT will be responsible for figuring out this resolution.

    Args:
        ctx: Repository rule context in which to execute commands
        packages: a map of package names to versions, or '*'/'' if no version is specified.

    Returns:
        A map from package name to list of packages that are required.
    """
    fail("Not yet implemented.")
    dependency_tree = {}

    for package_name, package_version in packages.items():
        # Ignore packages that have already been processed.
        if package_name in dependency_tree:
            continue

        # Compute the dependency list for this package.
        deps_result = ctx.execute(
            ["apt-cache", "depends", package_name],
        )

        # Recurse each dependency in this list and populate the result.
        compute_package_dependency_tree(ctx, packages)

    return {}

def _deb_archive_impl(ctx):
    # Compile the full list of packages that need to be retrieved.
    # For each package, assemble a dependency tree of some kind.
    # Convert each package into a repository rule?
    # Export cc_library for each package.

    # Create a header for the root buildfile for this repository.
    root_buildfile = """
    # Buildfile for '{name}' deb_archive.
    """.format(name = ctx.name)
    ctx.file("BUILD", root_buildfile, executable = False)

    # Create repository rules for each package.
    for package_name, package_version in ctx.attr.packages.items():
        # TODO: convert package version.
        if package_version == "*":
            package_version = None
        package_query = package_name if not package_version else "{}={}".format(package_name, package_version)

        # Use APT tooling to fetch a list of installation URIs.
        ctx.report_progress("Fetch URI for {}".format(package_query))
        uri_result = ctx.execute(
            ["apt-get", "-qq", "install", "--reinstall", "--print-uris", package_query],
        )
        if uri_result.return_code:
            fail("Unable to resolve package URI for '{}'".format(package_name))

        # Extract a list of URIs from the result.
        uris = [uri.split(" ")[0].replace("'", "") for uri in uri_result.stdout.splitlines()]

        for uri in uris:
            # Construct a bunch of names and paths from each package URI.
            uri_deb = uri.rsplit("/", 1)[1]
            uri_name, uri_version, arch = uri_deb.split("_")
            uri_sha256 = get_package_sha256(ctx, uri_name, uri_version)
            uri_deb_path = "{}/{}".format(package_name, uri_deb)
            uri_data_path = "{}/{}".format(package_name, "data.tar.xz")

            # Download the actual debian file from the APT repository.
            download_result = ctx.download(uri, uri_deb_path, sha256 = uri_sha256)
            if not download_result.success:
                fail("Failed to download deb '{}'".format(uri))

            # Unpack the data component of the debian file.
            unpack_result = ctx.execute(
                ["ar", "x", uri_deb, "data.tar.xz"],
                working_directory = package_name,
            )
            if unpack_result.return_code:
                fail("Unable to unpack 'data.tar.xz' from deb '{}'".format(uri_deb))

            # Extract the data component into the local directory.
            extract_result = ctx.extract(uri_data_path, output = package_name, stripPrefix = "")

        # Add the content of these packages to a library directive.
        buildfile = """
filegroup(
    name = "files",
    srcs = glob([
        "usr/**/*"
    ]),
    visibility = ["//visibility:public"],
)

cc_library(
    name = "cc",
    hdrs = glob(["usr/include/**/*"]),
    srcs = glob(["usr/lib/**/*"]),
    strip_include_prefix = "usr/include",
    visibility = ["//visibility:public"],
)
        """.format(package_name = package_name)

        # Create the final buildfile including all the aggregated package rules.
        ctx.file("{}/BUILD".format(package_name), buildfile, executable = False)

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
