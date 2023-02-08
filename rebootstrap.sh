#!/bin/ksh
#
# Copyright (c) 2019,2022 Sebastien Marie <semarie@online.fr>
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
BMIRROR=''

# base mirror: see http://ftp.hostserver.de/archive/YYYY-MM-DD-ZZZZ

while getopts 'a:m:b:' arg; do
	case ${arg} in
	a)	ARCH=${OPTARG}
		;;
	m)	MIRROR=${OPTARG}
		[[ ${BMIRROR} = '' ]] && BMIRROR=${MIRROR}
		;;
	b)	BMIRROR=${OPTARG}
		;;
	*)	echo "usage: ${0##*/} [-a arch] [-m mirror] [-b basemirror]" >&2
		exit 1
		;;
	esac
done

[[ ${BMIRROR} = '' ]] && BMIRROR=${MIRROR}

# ensure third-parties programs to be present before running
if ! command -v llvm-strip >/dev/null; then
	echo "error: llvm-strip missing: please install llvm package" >&2
	exit 1
fi

MIRRORBASE="${BMIRROR}/snapshots/${ARCH}"
MIRRORPORTS="${MIRROR}/snapshots/packages/${ARCH}"

TMPDIR=$(mktemp -d -t rebootstrap.XXXXXXXXXX) || exit 1
PORTSINDEX="${TMPDIR}/index.txt"
PORTSDIR="${TMPDIR}/ports"

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
==>> arch: ${ARCH}
==>> base mirror: ${BMIRROR}
==>> mirror: ${MIRROR}
EOF

# get base version
set -A _KERNV -- $(sysctl -n kern.version |
	sed 's/^OpenBSD \([1-9][0-9]*\)\.\([0-9]\)\([^ ]*\).*/\1 \2 \3/;q')
BV=${_KERNV[0]}${_KERNV[1]}
echo "==>> OpenBSD base${BV}"

# get base signature
ftp -Vmo "${TMPDIR}/SHA256.sig" \
	"${MIRRORBASE}/SHA256.sig"

# get base tarball
ftp -Vmo "${TMPDIR}/base${BV}.tgz" \
	"${MIRRORBASE}/base${BV}.tgz"

# verify base tarball
( cd "${TMPDIR}" && signify -C -p "/etc/signify/openbsd-${BV}-base.pub" -x SHA256.sig "base${BV}.tgz" )

# get index of packages
mkdir "${PORTSDIR}"
ftp -Vmo- "${MIRRORPORTS}" \
	| sed -ne 's|.* href="\([^"]*\.tgz\)".*|\1|p' \
	> "${PORTSINDEX}"

# get rust version
RV=$(sed -ne 's/^rust-\([0-9].*\)\.tgz$/\1/p' "${PORTSINDEX}")
echo "==>> Rust version ${RV}"

# process ports bootstrap dependencies
for pkgname in rust curl nghttp2 nghttp3 libgit2 libssh2 ngtcp2 ${eports} ; do
	pkgfile=$(grep -- "^${pkgname}-[0-9].*\.tgz" "${PORTSINDEX}")

	# download, verify, extract
	ftp -Vmo - "${MIRRORPORTS}/${pkgfile}" \
		| signify -Vz -t pkg \
		| tar zxf - -C "${PORTSDIR}"
done

# extract base libraries
mkdir "${TMPDIR}/base"
tar zxf "${TMPDIR}/base${BV}.tgz" \
	-C "${TMPDIR}/base" \
	'./usr/lib/lib*.so*'

# generate bootstrap directory
BOOTSTRAPDIR="${PWD}/rustc-bootstrap-${ARCH}-${RV}-$(date +%Y%m%d)"
mkdir "${BOOTSTRAPDIR}"

echo "==>> Creating bootstrap directory: ${BOOTSTRAPDIR}"

# copy files for bootstrap: bin
mkdir "${BOOTSTRAPDIR}/bin"
for i in rustc rustdoc cargo ; do
	cp "${PORTSDIR}/bin/$i" "${BOOTSTRAPDIR}/bin/$i"
	llvm-strip "${BOOTSTRAPDIR}/bin/$i"
	chmod 0755 "${BOOTSTRAPDIR}/bin/$i"
done

# copy files for bootstrap: rustlib
mkdir "${BOOTSTRAPDIR}/lib"
cp -R "${PORTSDIR}/lib/rustlib" "${BOOTSTRAPDIR}/lib"
find "${BOOTSTRAPDIR}/lib/rustlib" -name 'lib*.so*' -execdir llvm-strip {} \;

# copy required libraries
addlibs() {
	local f

	readelf -d "$1" \
	| sed -ne 's/.*Shared library:.*\[\([^]]*\)].*/\1/p' \
	| while read name ; do
		path=""

		# search path (ports, base). last match wins.
		[[ -r ${PORTSDIR}/lib/${name} ]] && path=${PORTSDIR}/lib/${name}
		[[ -r ${TMPDIR}/base/usr/lib/${name} ]] && path=${TMPDIR}/base/usr/lib/${name}

		# name not found
		if [[ ${path} = "" ]] ; then
			echo "error: library not found: $1: ${name}" >&2
			exit 1
		fi

		# already copied, skip
		[[ -r ${BOOTSTRAPDIR}/lib/${name} ]] && continue

		# copy (or link if under rustlib/)
		if [[ ! -r "${BOOTSTRAPDIR}/lib/rustlib/${triple_arch}/lib/${name}" ]] ; then
			llvm-strip "${path}"
			cp "${path}" "${BOOTSTRAPDIR}/lib"
		else
			ln -s "rustlib/${triple_arch}/lib/${name}" "${BOOTSTRAPDIR}/lib/${name}"
		fi

		# recursively add libs
		addlibs "${path}"
	done
}

for elf in "${BOOTSTRAPDIR}/bin/"* "${BOOTSTRAPDIR}/lib/rustlib/${triple_arch}/codegen-backends/"lib*.so ; do
	[[ ! -r "${elf}" ]] && continue
	addlibs "${elf}"
done

# cleaning
rm -rf -- "${TMPDIR}"
