#!/usr/bin/env python3
"""Detect which add-ons had their config.yaml version bumped, and emit a build
matrix for the publish workflow.

An add-on is published only when the ``version:`` in its ``config.yaml`` differs
from the previous commit (``BEFORE``). This means routine changes to ``main``
that do not bump a version produce no image, and only the add-on whose version
changed is built - not every add-on in the repo.

Environment variables:
  BEFORE      Git sha of the previous commit (github.event.before). If empty or
              all-zeros (first push / new branch), every add-on is treated as
              changed.
  SHA         Git sha to read the current config from (default: HEAD).
  FORCE_ADDON Publish this specific add-on (dir name or slug) regardless of the
              version diff. Used by manual workflow_dispatch.
  FORCE_ALL   "true" to publish every add-on regardless of the version diff.
  OWNER       Repository owner, used to derive the image name when config.yaml
              has no explicit ``image:`` key.
  REGISTRY    Container registry host (default: ghcr.io).

Outputs (written to GITHUB_OUTPUT when set):
  matrix       JSON object {"include": [ ... ]} for the build job's matrix.
  has_changes  "true" when at least one image will be built, else "false".
"""

from __future__ import annotations

import json
import os
import subprocess
import sys

import yaml

# Home Assistant arch name -> Docker buildx platform.
ARCH_PLATFORM = {
    "aarch64": "linux/arm64",
    "amd64": "linux/amd64",
    "armv7": "linux/arm/v7",
    "armhf": "linux/arm/v6",
    "i386": "linux/386",
}


def git_show(ref: str, path: str) -> str | None:
    """Return the contents of ``path`` at ``ref``, or None if it does not exist."""
    try:
        return subprocess.check_output(
            ["git", "show", f"{ref}:{path}"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except subprocess.CalledProcessError:
        return None


def load_yaml(text: str | None) -> dict:
    if not text:
        return {}
    return yaml.safe_load(text) or {}


def find_addon_dirs() -> list[str]:
    """Every top-level directory that contains a config.yaml is an add-on."""
    dirs = []
    for entry in sorted(os.listdir(".")):
        if os.path.isfile(os.path.join(entry, "config.yaml")):
            dirs.append(entry)
    return dirs


def main() -> None:
    before = os.environ.get("BEFORE", "").strip()
    sha = os.environ.get("SHA", "HEAD").strip() or "HEAD"
    force_addon = os.environ.get("FORCE_ADDON", "").strip()
    force_all = os.environ.get("FORCE_ALL", "").strip().lower() == "true"
    owner = os.environ.get("OWNER", "").strip().lower()
    registry = os.environ.get("REGISTRY", "ghcr.io").strip()

    # A missing or all-zero BEFORE means there is no previous commit to diff
    # against (first push, new branch), so treat everything as changed.
    no_before = (not before) or set(before) <= {"0"}

    include: list[dict] = []

    for addon in find_addon_dirs():
        cfg_path = f"{addon}/config.yaml"
        current = load_yaml(git_show(sha, cfg_path))
        slug = str(current.get("slug") or addon)
        version = str(current.get("version") or "").strip()
        arches = current.get("arch") or []

        if not version or not arches:
            print(f"::warning::{addon}: missing version or arch, skipping", file=sys.stderr)
            continue

        publish = False
        reason = ""
        if force_addon:
            if force_addon in (addon, slug):
                publish, reason = True, "forced add-on"
        elif force_all:
            publish, reason = True, "manual force-all"
        elif no_before:
            publish, reason = True, "no previous commit"
        else:
            previous = load_yaml(git_show(before, cfg_path))
            old_version = str(previous.get("version") or "").strip()
            if old_version != version:
                publish, reason = True, f"{old_version or 'none'} -> {version}"

        if not publish:
            print(f"{addon}: unchanged (version {version}), skipping", file=sys.stderr)
            continue

        build = load_yaml(
            open(f"{addon}/build.yaml").read()
            if os.path.isfile(f"{addon}/build.yaml")
            else None
        )
        build_from = build.get("build_from") or {}
        image_tmpl = str(current.get("image") or "").strip()

        for arch in arches:
            platform = ARCH_PLATFORM.get(arch)
            if not platform:
                print(f"::warning::{addon}: unknown arch '{arch}', skipping", file=sys.stderr)
                continue
            if image_tmpl:
                image = image_tmpl.replace("{arch}", arch)
            else:
                image = f"{registry}/{owner}/{slug}-{arch}"
            include.append(
                {
                    "addon": addon,
                    "slug": slug,
                    "arch": arch,
                    "version": version,
                    "platform": platform,
                    "build_from": build_from.get(arch, ""),
                    "image": image,
                }
            )

        print(f"{addon}: PUBLISH ({reason}) version={version} arches={arches}", file=sys.stderr)

    matrix = {"include": include}
    has_changes = "true" if include else "false"

    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a") as fh:
            fh.write(f"matrix={json.dumps(matrix)}\n")
            fh.write(f"has_changes={has_changes}\n")

    print(json.dumps(matrix, indent=2), file=sys.stderr)


if __name__ == "__main__":
    main()
