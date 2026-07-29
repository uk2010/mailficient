# Flatpak build and installation

Mailficient's complete Flatpak source is kept in the Git repository. The
application code is under `src/`, tests are under `tests/`, installed resources
are under `data/`, and the build entry point is
`packaging/com.local.Mailficient.Devel.json`.

The manifest builds:

- libical 3.0.20 from its pinned upstream Git commit
- Evolution Data Server 3.60.2 from its checksum-pinned GNOME archive
- Mailficient from the complete repository source tree

No generated Flatpak build directory or private account data is required from
the repository.

## Install a release bundle

Download `Mailficient-0.1.5-x86_64.flatpak` and its checksum from the GitHub
release. Verify and install them from the download directory:

```sh
sha256sum -c Mailficient-0.1.5-x86_64.flatpak.sha256
flatpak install --user ./Mailficient-0.1.5-x86_64.flatpak
flatpak run --user com.local.Mailficient
```

The current release bundle targets x86-64. The runtime is downloaded from
Flathub when it is not already installed.

## Build from source

Install Flatpak and Flatpak Builder using the Linux distribution's package
manager. Add Flathub and install the GNOME 49 build/runtime pair:

```sh
flatpak remote-add --user --if-not-exists flathub \
  https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user flathub \
  org.gnome.Platform//49 org.gnome.Sdk//49
```

From the root of a Mailficient checkout, build, test, install, and run:

```sh
flatpak-builder --user --install --force-clean \
  flatpak-build packaging/com.local.Mailficient.Devel.json
flatpak run --user com.local.Mailficient
```

`run-tests` is enabled in the manifest, so both the core and Camel boundary
suites must pass before Flatpak Builder completes.

## Create a single-file bundle

Build into a local repository and export the application bundle:

```sh
flatpak-builder --force-clean \
  --repo=flatpak-repo \
  flatpak-build packaging/com.local.Mailficient.Devel.json

flatpak build-bundle \
  --runtime-repo=https://flathub.org/repo/flathub.flatpakrepo \
  flatpak-repo \
  Mailficient-0.1.5-x86_64.flatpak \
  com.local.Mailficient \
  master

sha256sum Mailficient-0.1.5-x86_64.flatpak \
  > Mailficient-0.1.5-x86_64.flatpak.sha256
```

Build output, repositories, bundles, and local mail data are excluded from
Git. Only reproducible source inputs and documentation are committed.
