default:
    just --list

build:
    zig build

run *args='':
    zig build run -- {{args}}

test:
    zig build test

fmt:
    zig fmt src/ build.zig
