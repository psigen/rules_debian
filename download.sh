#!/bin/bash
#
# Downloads a list of debs and produces an output tar that contains the contents of all of the required debs.
#

for i in $(apt-cache depends python | grep -E 'Depends|Recommends|Suggests' | cut -d ':' -f 2,3 | sed -e s/'<'/''/ -e s/'>'/''/); do
    apt-get download $i 2>>errors.txt
done
