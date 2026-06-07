FROM alpine:3.19

# Install build dependencies
RUN apk add --no-cache curl tar xz build-base

# Download and install Zig 0.13.0 based on build architecture (x86_64 or aarch64)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ZIG_ARCH="linux-x86_64"; \
    elif [ "$ARCH" = "aarch64" ]; then ZIG_ARCH="linux-aarch64"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    curl -O https://ziglang.org/download/0.13.0/zig-$ZIG_ARCH-0.13.0.tar.xz && \
    tar -xf zig-$ZIG_ARCH-0.13.0.tar.xz && \
    mv zig-$ZIG_ARCH-0.13.0 /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig && \
    rm -rf zig-$ZIG_ARCH-0.13.0.tar.xz

# Set up app directory
WORKDIR /app
COPY . .

# Build the database server and tests using the build.zig we created
RUN zig build -Doptimize=ReleaseSafe

# Expose database ports
EXPOSE 9000 9001 9002

# The entrypoint runs the database executable
ENTRYPOINT ["/app/zig-out/bin/database"]
