def _deb_archive_impl(ctx):
    # Compile the full list of packages that need to be retrieved.
    # For each package, assemble a dependency tree of some kind.
    # Convert each package into a repository rule?
    # Export cc_library for each package.

    # Create repository rules for each package.
    for package, version in ctx.attr.packages.items():
        # Use APT tooling to fetch a list of installation URIs.
        ctx.report_progress("Fetch URI for %s" % package)
        uri_result = ctx.execute(
            ["apt-get", "-qq", "install", "--reinstall", "--print-uris", package],
        )
        if uri_result.return_code:
            fail("Unable to resolve package URI for %s" % package)

        # Extract just a list of URIs and from the result.
        uris = [uri.split(" ")[0].replace("'", "") for uri in uri_result.stdout.splitlines()]
        print(uris)

        for uri in uris:
            ctx.download(uri, package)

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
