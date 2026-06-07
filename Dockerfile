FROM alpine:3.19

# Install build dependencies
RUN apk add --no-cache curl tar xz build-base

# Download and install Zig 0.16.0 based on build architecture (x86_64 or aarch64)
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then ZIG_ARCH="x86_64-linux"; \
    elif [ "$ARCH" = "aarch64" ]; then ZIG_ARCH="aarch64-linux"; \
    else echo "Unsupported architecture: $ARCH" && exit 1; fi && \
    curl -L -O https://ziglang.org/download/0.16.0/zig-$ZIG_ARCH-0.16.0.tar.xz && \
    tar -xf zig-$ZIG_ARCH-0.16.0.tar.xz && \
    mv zig-$ZIG_ARCH-0.16.0 /opt/zig && \
    ln -s /opt/zig/zig /usr/local/bin/zig && \
    rm -rf zig-$ZIG_ARCH-0.16.0.tar.xz

# Set up app directory
WORKDIR /app
COPY . .

# Build the database server and tests using the build.zig we created
RUN zig build -Doptimize=ReleaseSafe

# Expose database ports
EXPOSE 9000 9001 9002

# The entrypoint runs the database executable
ENTRYPOINT ["/app/zig-out/bin/database"]
