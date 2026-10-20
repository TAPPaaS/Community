# mikrotik-controller's runtime (ADR-035 D10): Python with Ansible, its
# community.routeros collection, and librouteros — from the nixpkgs tappaas-cicd's
# flake.lock pins, so the versions move with the release. install.sh builds it
# and GC-roots it; nothing is installed on the mothership's system.
{ pkgs }:
pkgs.python3.withPackages (ps: [ ps.ansible ps.ansible-core ps.librouteros ])
