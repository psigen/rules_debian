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

def _get_control_fields(control):
    """
    Gets a dict of field entries from a debian control file.

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
            field_content += line
            continue

        # If this is a new field, finish the previous field before starting this one.
        if field_name:
            fields[field_name] = field_content

        # If this is a blank line, move to the next one.
        if not line.strip():
            continue

        # Start storing the content of the new field.
        field_name, field_content = line.split(":", 1)

    return fields

def _get_control_depends(control):
    """
    Gets the package names of the 'Depends:' directive in a debian control file.

    References:
        https://www.debian.org/doc/debian-policy/ch-controlfields.html#s-controlsyntax
        https://www.debian.org/doc/debian-policy/ch-relationships.html#declaring-relationships-between-packages

    Args:
        control: the string content of a debian control file.
    Returns:
        A list of package names from the control file Depends directive.
    """
    depends = []
    fields = _get_control_fields(control)

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

def _setup_package(ctx, package_name, package_uri, package_list, export_cc):
    # Construct a bunch of names and paths from each package URI.
    uri_filename, uri_name, uri_version, uri_arch = _get_package_uri_props(package_uri)

    sha256 = _get_package_sha256(ctx, uri_name, uri_version)
    deb_path = "{}/{}".format(package_name, uri_filename)
    data_path = "{}/{}".format(package_name, "data.tar.xz")
    control_path = "{}/{}".format(package_name, "control.tar.xz")

    # Download the actual debian file from the APT repository.
    download_result = ctx.download(package_uri, deb_path, sha256 = sha256)
    if not download_result.success:
        fail("Failed to download deb '{}'".format(package_uri))

    # Unpack the data and control components of the debian file.
    unpack_result = ctx.execute(
        ["ar", "x", uri_filename, "data.tar.xz", "control.tar.xz"],
        working_directory = package_name,
    )
    if unpack_result.return_code:
        fail("Unable to unpack 'data.tar.xz' from deb '{}'".format(uri_filename))

    # Extract the components into the local directory.
    ctx.extract(data_path, output = package_name, stripPrefix = "")
    ctx.extract(control_path, output = package_name, stripPrefix = "")

    # Use the control file to figure out the relevant dependencies of this package.
    # Only include dependencies that are being installed as part of this archive target.
    control = ctx.read("{}/{}".format(package_name, "control"))
    control_deps = _get_control_depends(control)
    package_deps = [dep for dep in control_deps if dep in package_list]

    # Add the content of these packages to a library directive.
    buildfile = BUILDFILE_BASE
    if (export_cc):
        buildfile += BUILDFILE_CC.format(
            cc_deps = ", ".join(["\"//{}:cc\"".format(dep) for dep in package_deps]),
        )

    # Create the final buildfile including all the aggregated package rules.
    ctx.file("{}/BUILD".format(package_name), buildfile, executable = False)

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
        packages[uri_name] = {
            "uri": uri,
            "filename": uri_filename,
            "version": uri_version,
            "arch": uri_arch,
        }

    # Create repository rules for each package.
    for package_name, package_info in packages.items():
        _setup_package(
            ctx,
            package_name,
            package_info["uri"],
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
