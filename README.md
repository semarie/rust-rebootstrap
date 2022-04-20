# rust-rebootstrap

rebootstrap.sh is a shell script for helping myself to generate bootstrap tarball
for [OpenBSD ports tree](http://cvsweb.openbsd.org/ports/lang/rust), for architectures
I don't have access to (but which have already been ported).

It will download snapshots elements from base (for libraries, like libc.so for example),
and from ports (for rust, curl or others rust dependencies), and put them in a local
directory, suitable for generating a bootstrap compatible with lang/rust port.

This way, it is possible to "regenerate" a bootstrap using fresh binaries, and ease the
update of the bootstrap from version to version.

Please note that it is a maintenance tool only. It is unable to generate bootstrap for
an architecture which doesn't have initial rust port.
