# The digest pins both native architectures. No package upgrade or floating index.
FROM alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc
# The verified index pins direct and transitive versions; apk fetch accepts package names, not name=version constraints.
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
      gcc g++ make perl python3 musl musl-dev linux-headers \
      patchelf binutils ca-certificates \
 && apk add --no-network /packages/*.apk \
 && apk info -v > /minga-erts-packages.txt \
 && printf '%s\n' 'alpine@sha256:d9e853e87e55526f6b2917df91a2115c36dd7c696a35be12163d44e6e2a4b6bc' > /minga-erts-base-image \
 && rm -rf /locked /packages
