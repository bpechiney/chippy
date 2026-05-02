default:
    just --list

build:
    zig build

run *args='':
    zig build run -- {{args}}

test:
    zig build test

# Merge gate: build + run all tests inside the pinned dev shell.
check:
    nix develop -c zig build test

fmt:
    zig fmt src/ build.zig

# CI parity: verify everything is already formatted, no rewrites.
fmt-check:
    nix develop -c zig fmt --check src/ build.zig
