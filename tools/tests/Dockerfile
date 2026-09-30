FROM ubuntu:26.04
RUN apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends systemd python3 python3-yaml python3-jsonschema curl ca-certificates squashfs-tools && rm -rf /var/lib/apt/lists/*
