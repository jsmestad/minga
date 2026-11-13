# The digest pins both native architectures. No package upgrade or floating index.
FROM alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
RUN printf '%s\n' 'https://dl-cdn.alpinelinux.org/alpine/v3.20/main' > /etc/apk/repositories \
 && mkdir /locked /packages \
 && apk --cache-dir /locked update \
 && case "$(uname -m)" in \
      x86_64) expected=85cc20ba8f0c7ac174d88f6db3f0b689c61109332ff8fa39f317316555a6feb5 ;; \
      aarch64) expected=c9a6f6d02d08fd53bb54b179edd89eb279dd7fe693d74ed098eb503df8e14c7c ;; \
      *) exit 1 ;; \
    esac \
 && set -- /locked/APKINDEX.*.tar.gz \
 && test "$#" = 1 \
 && printf '%s  %s\n' "$expected" "$1" | sha256sum -c - \
 && apk --cache-dir /locked fetch --recursive --output /packages \
      gcc=13.2.1_git20240309-r1 g++=13.2.1_git20240309-r1 \
      make=4.4.1-r2 perl=5.38.5-r0 python3=3.12.13-r0 \
      musl=1.2.5-r4 musl-dev=1.2.5-r4 linux-headers=6.6-r0 \
      patchelf=0.18.0-r3 binutils=2.42-r1 ca-certificates=20261020-r0 \
 && apk add --no-network /packages/*.apk \
 && apk info -v > /minga-erts-packages.txt \
 && printf '%s\n' 'alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc' > /minga-erts-base-image \
 && rm -rf /locked /packages
