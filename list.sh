#!/bin/bash
#
# Downloads a list of debs and produces an output tar that contains the contents of all of the required debs.
#


# for i in $(apt-cache depends python | grep -E 'Depends|Recommends|Suggests' | cut -d ':' -f 2,3 | sed -e s/'<'/''/ -e s/'>'/''/); do
#     apt-cache show $i 2>>errors.txt
# done

# See: https://unix.stackexchange.com/a/188983
PACKAGE=libboost-dev
apt-cache policy $(apt-rdepends -p ${PACKAGE} 2>| /dev/null|awk '/Depends/ {print $2}' | sort -u) | awk '/^[^ ]/ { package=$0 } /  Installed/ { print package " " $2 }'
