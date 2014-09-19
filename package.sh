#!/usr/bin/env bash
cabal configure && cabal build && cabal haddock --hyperlink-source \
                                    --html-location='/package/$pkg-$version/docs' \
                                    --contents-location='/package/$pkg'
S=$?
if [ "${S}" -eq "0" ]; then
    cd "dist/doc/html"
    DDIR="${1}-${2}-docs"
    cp -r "${1}" "${DDIR}" && tar -c -v -z --format=ustar -f "${DDIR}.tar.gz" "${DDIR}"
    CS=$?
    if [ "${CS}" -eq "0" ]; then
        echo "Uploading to Hackage…"
        curl -u XXXXX:XXXXX -X PUT -H 'Content-Type: application/x-tar' -H 'Content-Encoding: gzip' --data-binary "@${DDIR}.tar.gz" "http://${3}:${4}@hackage.haskell.org/package/${1}-${2}/docs"
        exit $?
    else
        echo "Error when packaging the documentation"
        exit $CS
    fi
else
    echo "Error when trying to build the package."
    exit $S
fi
