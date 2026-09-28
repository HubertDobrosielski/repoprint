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

Each run creates a new output file inside `repoprint-out/`. Previous outputs are kept.

```text
repoprint-out/
├── out-1759081234567890000.txt
├── out-1759081298765432000.txt
└── ...
```

The `repoprint-out/` directory is always ignored by `repoprint`.

## Ignore Rules

Create a `.repoprintignore` file in the repository root to exclude files or directories.

```text
node_modules/
*.png
```

Prefix a rule with `@content` to keep the file or directory in the repository tree but skip its contents:

```text
@content package-lock.json
@content *.json
```

## Wildcards

Use `*` at the beginning or end of a pattern for partial matching.

```text
*.png
```

Matches paths ending with `.png`.

```text
test*
```

Matches paths starting with `test`.

```text
*config*
```

Matches paths containing `config`.

Without `*`, the pattern must match the complete relative path:

```text
src/main.zig
```

The same wildcard rules apply to `@content` rules:

```text
@content *.json
@content test*
@content *config*
```
