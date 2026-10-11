## Zig good practices

- Each subfolder in "src" is a module. A module must never import directly a file from another module unless it is "src/<module>/exports.zig".
