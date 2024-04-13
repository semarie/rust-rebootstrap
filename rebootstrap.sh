#!/bin/ksh
#
# Copyright (c) 2019-2024 Sebastien Marie <semarie@kapouay.eu.org>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
#
PATH='/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/usr/local/sbin'
set -eu
umask 022

ARCH=$(machine -a)
MIRROR=$(sed 's/#.*//;/^$/d' /etc/installurl) 2>/dev/null ||
	MIRROR='https://cdn.openbsd.org/pub/OpenBSD'

while getopts 'a:m:b:' arg; do
	case ${arg} in
	a)	ARCH=${OPTARG}
		;;
	m)	MIRROR=${OPTARG}
		;;
	*)	echo "usage: ${0##*/} [-a arch] [-m mirror]" >&2
		exit 1
		;;
	esac
done

# ensure third-parties programs to be present before running
if ! command -v tarlz >/dev/null; then
	echo "error: tarlz missing: please install tarlz package" >&2
	exit 1
fi

MIRRORPORTS="${MIRROR}/snapshots/packages/${ARCH}"

TMPDIR=$(mktemp -d -t rebootstrap.XXXXXXXXXX) || exit 1
PORTSINDEX="${TMPDIR}/index.txt"
PORTSDIR="${TMPDIR}/ports"

trap "rm -rf -- '${TMPDIR}'" 1 2 3 13 15 ERR EXIT

# arch dependant configuration
case "${ARCH}" in
aarch64)
	triple_arch=aarch64-unknown-openbsd
	eports=
	;;
amd64)
	triple_arch=x86_64-unknown-openbsd
	eports=
	;;
i386)
	triple_arch=i686-unknown-openbsd
	eports=
	;;
powerpc64)
	triple_arch=powerpc64-unknown-openbsd
	eports=
	;;
riscv64)
	triple_arch=riscv64gc-unknown-openbsd
	eports=
	;;
sparc64)
	triple_arch=sparc64-unknown-openbsd
	eports=gcc-libs
	;;
*)
	echo "error: unsupported architecture: ${ARCH}" >&2
	exit 1
esac

cat <<EOF
==>> arch: ${ARCH} (${triple_arch})
==>> mirror: ${MIRROR}
EOF

# get index of packages
mkdir "${PORTSDIR}"
echo "==>> Package index"
ftp -Vmo- "${MIRRORPORTS}" \
	| sed -ne 's|.* href="\([^"]*\.tgz\)".*|\1|p' \
	> "${PORTSINDEX}"

# get rust version
RV=$(sed -ne 's/^rust-bootstrap-\([0-9].*\)\.tgz$/\1/p' "${PORTSINDEX}")
if [ -z "${RV}" ]; then
	echo "error: no rust-bootstrap package in index" >&2
	exit 1
fi
echo "==>> Rust version: ${RV}"

# get rust-bootstrap package
pkgfile=$(grep -- "^rust-bootstrap-[0-9].*\.tgz" "${PORTSINDEX}")

# download, verify, extract
ftp -Vmo - "${MIRRORPORTS}/${pkgfile}" \
	| signify -Vz -t pkg \
	| tar zxf - -C "${PORTSDIR}"

BOOTSTRAPARC="rustc-bootstrap-${ARCH}-${RV}.tar.lz"

echo "==>> Creating bootstrap archive: ${BOOTSTRAPARC}"
tarlz --solid -z \
	${PORTSDIR}/lib/rustc-bootstrap-${ARCH}.tar \
	-o "${BOOTSTRAPARC}"

exit 0
