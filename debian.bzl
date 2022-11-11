"""
Repository rules for interacting with debian repositories.
"""

BUILDFILE_BASE = """
filegroup(
    name = "files",
    srcs = glob([
        "usr/**/*"
    ]),
    visibility = ["//visibility:public"],
)
"""

BUILDFILE_CC = """
cc_library(
    name = "cc",
    hdrs = glob(["usr/include/**/*"]),
    srcs = glob(["usr/lib/**/*"]),
    strip_include_prefix = "usr/include",
    visibility = ["//visibility:public"],
    deps = [{cc_deps}],
)
"""

def _get_package_uri_props(package_uri):
    """
    Gets the properties of a debian package from its URI.
    """
    uri_filename = package_uri.rsplit("/", 1)[1]
    uri_basename = uri_filename.rsplit(".", 1)[0]
    uri_name, uri_version, uri_arch = uri_basename.split("_")
    return uri_filename, uri_name, uri_version, uri_arch

def _get_package_sha256(ctx, package_name, package_version = None):
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

    # Use APT cache to get package information.
    cache_result = ctx.execute(
        ["apt-cache", "show", "--no-all-versions", package_query],
    )
    if cache_result.return_code:
        fail("Unable to retrieve package SHA256 for {}".format(package_query))

    # Extract the SHA256 hash from the returned package information.
    for line in cache_result.stdout.splitlines():
        if line.startswith("SHA256"):
            return line.split(" ")[1]

    fail("Unable to find a package SHA256 for {}".format(package_query))

def _parse_control_fields(control):
    """
    Parse a dict of field entries from a debian control file.

    References:
        https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-controlsyntax
    Args:
        control: the string content of a debian control file.
    Returns:
        a dict containing the field entries from the control file.
    """
    fields = {}

    field_name = None
    field_content = None

    for idx, line in enumerate(control.splitlines()):
        # Ignore comment lines as per control-file spec.
        if line.startswith("#"):
            continue

        # If the field starts with whitespace, it is a folded or multiline field.
        # Add it to the content of the ongoing field or error if there is none.
        if line.startswith(" ") or line.startswith("\t"):
            if not field_name:
                fail("Unexpected folded line in control file: line {}".format(idx))
            field_content += line.lstrip()
            continue

        # If this is a new field, finish the previous field before starting this one.
        if field_name:
            fields[field_name] = field_content.strip()

        # If this is a blank line, move to the next one.
        if not line.strip():
            continue

        # Start storing the content of the new field.
        field_name, field_content = line.split(":", 1)

    return fields

def _parse_control_depends(fields):
    """
    Parse the package names of the 'Depends:' directive in a debian control file.

    References:
        https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-controlsyntax
        https://www.debian.org/doc/debian-policy/ch-relationships.html#declaring-relationships-between-packages

    Args:
        fields: a parsed map of field strings from a debian control file.
    Returns:
        A list of package names from the control file Depends directive.
    """
    depends = []

    for entry in [fields.get("Depends", None), fields.get("Pre-Depends", None)]:
        # Skip the fields if they were empty.
        if not entry:
            continue

        # Remove newlines, these are 'folded' fields so newlines are ignored.
        line = entry.replace("\n", "").replace("\r", "")

        # Move through each section extracting the packages names.
        for section in entry.split(","):
            for alternative in section.split("|"):
                depend = alternative.strip().split(" ", 1)[0]
                if depend not in depends:
                    depends.append(depend)

    return depends

def _get_package_dependencies(ctx, package_name, package_version = None):
    """
    Gets the list of other packages that a particular package depends on.

    Args:
        ctx: Repository rule context in which to execute commands
        package_name: name of the ubuntu package to query
        package_version: optional specific version string of the package to retrieve

    Returns:
        A map from package names to package versions on which this package depends.
        It may include transitive dependencies.
    """

    # Combine package name and version into query string if provided.
    if package_version == "*":
        package_version = None
    package_query = package_name if not package_version else "{}={}".format(package_name, package_version)

    # TODO: replace this with a more efficient command.
    # Retrieve the URIs of packages that would be installed with this package.
    uri_result = ctx.execute(
        ["apt-get", "-qq", "install", "--reinstall", "--print-uris", package_query],
    )
    if uri_result.return_code:
        fail("Unable to resolve package URIs for '{}'".format(package_name))

    # Convert this list of URIs to a list of package names.
    uris = [uri.split(" ")[0].replace("'", "") for uri in uri_result.stdout.splitlines()]
    deps_names = [_get_package_uri_props(uri)[1] for uri in uris]

    # Remove the original package from this list.
    return [name for name in deps_names if name != package_name]

def _download_package(ctx, package_name, package_path, package_uri, package_sha256):
    # Construct a bunch of names and paths from each package URI.
    deb_filename = "{}.deb".format(package_name)
    deb_path = "{}/{}".format(package_path, deb_filename)
    data_path = "{}/{}".format(package_path, "data.tar.xz")
    control_path = "{}/{}".format(package_path, "control.tar.xz")

    # Download the actual debian file from the APT repository.
    download_result = ctx.download(package_uri, deb_path, sha256 = package_sha256)
    if not download_result.success:
        fail("Failed to download deb from '{}'".format(package_uri))

    # Unpack the data and control components of the debian file.
    unpack_result = ctx.execute(
        ["ar", "x", deb_filename, "data.tar.xz", "control.tar.xz"],
        working_directory = package_path,
    )
    if unpack_result.return_code:
        fail("Unable to unpack 'data.tar.xz' from deb '{}'".format(deb_filename))

    # Extract the components into the local directory.
    ctx.extract(data_path, output = package_path, stripPrefix = "")
    ctx.extract(control_path, output = package_path, stripPrefix = "")

    # Return the control parameters for this package.
    control = ctx.read("{}/{}".format(package_path, "control"))
    return _parse_control_fields(control)

def _setup_package(ctx, package_name, package_path, package_list, export_cc, build_file_content = None, build_file = None):
    # Use the control file to figure out the relevant dependencies of this package.
    # Only include dependencies that are being installed as part of this archive target.
    control = ctx.read("{}/{}".format(package_path, "control"))
    control_fields = _parse_control_fields(control)
    control_deps = _parse_control_depends(control_fields)
    package_deps = [dep for dep in control_deps if dep in package_list]

    # Add the content of these packages to a library directive.
    buildfile_out = BUILDFILE_BASE
    if export_cc:
        if build_file or build_file_content:
            fail("Can't use export_cc and build_file or build_file_content at the same time")
        buildfile_out += BUILDFILE_CC.format(
            cc_deps = ", ".join(["\"//{}:cc\"".format(dep) for dep in package_deps]),
        )
    elif build_file_content:
        buildfile_out = build_file_content
    elif build_file:
        buildfile_out = None
        ctx.symlink(build_file, "BUILD.bazel")

    # Unless a custom BUILD file was provided, create the final buildfile including all the aggregated package rules.
    if buildfile_out:
        ctx.file("{}/BUILD.bazel".format(package_path), buildfile_out, executable = False)

def _deb_archive_impl(ctx):
    """
    Create a bazel repository for a group of debian packages.

    Compile the full list of packages that need to be retrieved.
    For each package, assemble a dependency tree of some kind.
    Convert each package into a repository rule?
    Export cc_library for each package.
    """

    # Create a header for the root buildfile for this repository.
    root_buildfile = """
    # Buildfile for '{name}' deb_archive.
    """.format(name = ctx.name)
    ctx.file("BUILD", root_buildfile, executable = False)

    # Create a query list that is in the format that APT expects
    # e.g. package_name OR package_name=package_version
    package_queries = []
    for package_name, package_version in ctx.attr.packages.items():
        if package_version and package_version != "*":
            package_queries.append("{}={}".format(package_name, package_version))
        else:
            package_queries.append(package_name)

    # Query APT for a set of package URIs that would satisfy this set of dependencies.
    uri_result = ctx.execute(
        ["apt-get", "-qq", "install", "--reinstall", "--print-uris"] + package_queries,
    )
    if uri_result.return_code:
        fail("Unable to resolve package URIs for '{}'".format(ctx.name))

    # Convert this list of URIs into a dict of package information.
    uris = [uri.split(" ")[0].replace("'", "") for uri in uri_result.stdout.splitlines()]
    packages = {}
    for uri in uris:
        uri_filename, uri_name, uri_version, uri_arch = _get_package_uri_props(uri)
        uri_sha256 = _get_package_sha256(ctx, uri_name, uri_version)
        packages[uri_name] = {
            "uri": uri,
            "filename": uri_filename,
            "version": uri_version,
            "arch": uri_arch,
            "sha256": uri_sha256,
        }

    # Download each package.
    for package_name, package_info in packages.items():
        control_fields = _download_package(
            ctx,
            package_name,
            package_name,  # Also use package name for local subpath.
            package_info["uri"],
            package_info["sha256"],
        )

        # Check that the specified name matched the one in the control file.
        if control_fields["Package"] != package_name:
            fail("Package name '{}' did not match downloaded control file '{}'.".format(
                package_name,
                control_fields["Package"],
            ))

    # Create repository rules for each package.
    for package_name, package_info in packages.items():
        _setup_package(
            ctx,
            package_name,
            package_name,  # Also use package name for local subpath.
            packages.keys(),
            ctx.attr.export_cc,
        )

deb_archive = repository_rule(
    implementation = _deb_archive_impl,
    attrs = {
        "packages": attr.string_dict(
            mandatory = True,
            doc = "List of debian packages and versions to use",
        ),
        "export_cc": attr.bool(
            default = True,
            doc = "Export a cc_library target for each package",
        ),
        "strict_visibility": attr.bool(default = False),
    },
    doc = "Makes available a set of debian packages for use in builds.",
)

def _deb_package_impl(ctx):
    """
    Create a bazel repository for a single debian package.
    """
    _download_package(
        ctx,
        ctx.name,
        ".",  # Use local directory as desired output directory.
        ctx.attr.urls,
        ctx.attr.sha256,
    )
    _setup_package(
        ctx,
        ctx.name,
        ".",  # Use local directory as desired output directory.
        [],  # No dependencies specified.
        ctx.attr.export_cc,
        ctx.attr.build_file_content,
        ctx.attr.build_file,
    )

deb_package = repository_rule(
    implementation = _deb_package_impl,
    attrs = {
        "urls": attr.string_list(
            mandatory = True,
            doc = "List of URLs to retrieve the specific debian package of interest",
        ),
        "sha256": attr.string(
            mandatory = True,
            doc = "SHA256 checksum for this specific package",
        ),
        "export_cc": attr.bool(
            default = True,
            doc = "Export a cc_library target for this package",
        ),
        "build_file_content": attr.string(
            mandatory = False,
            doc = "BUILD file content to use; can't be combined with export_cc option",
        ),
        "build_file": attr.label(
            mandatory = False,
            doc = "BUILD file to use; can't be combined with export_cc option",
        ),
    },
    doc = "Makes available a set of debian packages for use in builds.",
)

def construct_package_url(base_url, dist, arch, sha256):
    """
    Construct a package URL for a debian package using the 'by-hash' path.

    See: https://wiki.debian.org/DebianRepository/Format#indices_acquisition_via_hashsums_.28by-hash.29
    Example: http://us.archive.ubuntu.com/ubuntu/dists/bionic/by-hash/SHA256/
    """
    return "{base_url}/dists/{dist}/binary-{arch}/by-hash/SHA256/{sha256}".format(
        base_url = base_url,
        dist = dist,
        arch = arch,
        sha256 = sha256,
    )

def _deb_packages_impl(ctx):
    """
    Create a bazel repository for a group of debian packages as a single target.
    """
    for package_name, package_sha256 in ctx.attr.packages.items():
        # Construct an array of full URLs for this particular package from each mirror.
        package_urls = [
            construct_package_url(
                base_url,
                ctx.attr.dist,
                ctx.attr.arch,
                package_sha256,
            )
            for base_url in ctx.attr.mirrors
        ]

        # Download and extract this package and return the control fields.
        control_fields = _download_package(
            ctx,
            package_name,
            package_name,  # Use package_name as desired output directory.
            package_urls,
            package_sha256,
        )

        # Check that the specified name matched the one in the control file.
        if control_fields["Package"] != package_name:
            fail("Package name '{}' did not match downloaded control file '{}'.".format(
                package_name,
                control_fields["Package"],
            ))

        # Create a bazel package around this debian package.
        # This generates usable targets that can be consumed by bazel.
        _setup_package(
            ctx,
            package_name,
            package_name,  # Use package_name as desired output directory.
            ctx.attr.packages.keys(),
            ctx.attr.export_cc,
        )

deb_packages = repository_rule(
    implementation = _deb_packages_impl,
    attrs = {
        "dist": attr.string(
            mandatory = True,
            doc = "Distribution to use in the APT repositories (e.g. 'bionic')",
        ),
        "arch": attr.string(
            default = "x86_64",
            doc = "Architecture of the packages to retrieve (default: x86_64)",
        ),
        "mirrors": attr.string_list(
            mandatory = True,
            doc = "List of base URLs for APT repository mirrors",
        ),
        "packages": attr.string_dict(
            mandatory = True,
            doc = "Dict from debian package names to SHA256 checksums",
        ),
        "export_cc": attr.bool(
            default = True,
            doc = "Export a cc_library target for this group",
        ),
    },
    doc = "Makes available a set of debian packages for use in builds.",
)
