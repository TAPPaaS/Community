# webhost:packages

Gives a Debian 13 container its packages from the webhost container instead of the internet.

What the consumer gets:

- apt reads `snapshot.debian.org` at the timestamp of its runtime's promoted lock, through apt-cacher-ng on the webhost container (port 3142).
- apt trusts only the Debian trixie archive and security keys pinned in `snapshots/keys/`.
- The site agent pulls the site's content from the webhost container's git mirror (port 80).

Packages are upgraded by the consumer's own `update.sh`. This service only points apt at the right snapshot.

The runtime is read from the consumer's declaration, `static` if it has none. `WEBHOST_SNAPSHOT=<ts>` and `WEBHOST_PINS=<file>` override the lock; the canary runs use them.

`delete-service.sh` puts the consumer back on `deb.debian.org`.

Declare it after `cluster:lxc`: `"dependsOn": ["cluster:lxc", "webhost:packages", ...]`.
