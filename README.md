# repoprint

A small CLI tool that prints a repository structure and file contents into a single text file.

## Build

```bash
zig build
```

## Run

```bash
zig build run
```

## Ignore Rules

Create a `.repoprintignore` file in the repository root to exclude files or directories.

```text
node_modules/
*.png
```

Prefix a rule with `@content` to keep the file in the directory tree but skip its contents:

```text
@content package-lock.json
@content *.json
```

Use `*` at the beginning or end of a pattern for suffix or prefix matching.
