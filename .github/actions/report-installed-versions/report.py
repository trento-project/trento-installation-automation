#!/usr/bin/env python3
"""Query installed Trento package versions via SSH and print a markdown summary."""

import re
import subprocess
import sys

SSH_OPTS = ["-o", "StrictHostKeyChecking=no", "-o", "BatchMode=yes"]


def query_versions(host, user, key_file, packages):
    """SSH into a host and return {package: version} for each package."""
    commands = [
        f"echo {pkg}:$(rpm -q --queryformat '%{{VERSION}}-%{{RELEASE}}' {pkg} 2>/dev/null || echo '-')"
        for pkg in packages
    ]
    remote_script = "; ".join(commands)
    result = subprocess.run(
        ["ssh", *SSH_OPTS, "-i", key_file, f"{user}@{host}", remote_script],
        capture_output=True, text=True
    )
    versions = {}
    if result.returncode != 0:
        for pkg in packages:
            versions[pkg] = "ERROR/UNREACHABLE"
        return versions

    for line in result.stdout.strip().splitlines():
        pkg, ver = line.split(":", 1)
        versions[pkg] = ver
    return versions


def short_label(fqdn):
    """control15sp4.example.com → 15.4"""
    match = re.match(r"(?:control|target)(\d+)sp(\d+)", fqdn.split(".")[0])
    return f"{match.group(1)}.{match.group(2)}" if match else fqdn.split(".")[0]


def render_table(hosts, packages, versions):
    """Render a markdown table with hosts as columns and packages as rows."""
    header = "| Package | " + " | ".join(f"`{short_label(h)}`" for h in hosts) + " |"
    separator = "|---------|" + "---|".join("" for _ in hosts) + "---|"
    rows = []
    for pkg in packages:
        cells = " | ".join(f"`{versions[h].get(pkg, '-')}`" for h in hosts)
        rows.append(f"| `{pkg}` | {cells} |")
    return "\n".join([header, separator, *rows])


def main():
    hosts_csv = sys.argv[1]
    user = sys.argv[2]
    key_file = sys.argv[3]
    control_packages = sys.argv[4].split(",")
    target_packages = sys.argv[5].split(",")

    all_hosts = hosts_csv.split(",")
    control_hosts = [h for h in all_hosts if h.split(".")[0].startswith("control")]
    target_hosts = [h for h in all_hosts if not h.split(".")[0].startswith("control")]

    versions = {}
    for host in control_hosts:
        versions[host] = query_versions(host, user, key_file, control_packages)
    for host in target_hosts:
        versions[host] = query_versions(host, user, key_file, target_packages)

    print("## Installed Package Versions")
    print()
    print("### Control Nodes")
    print()
    print(render_table(control_hosts, control_packages, versions))
    print()
    print("### Target Nodes")
    print()
    print(render_table(target_hosts, target_packages, versions))


if __name__ == "__main__":
    main()
