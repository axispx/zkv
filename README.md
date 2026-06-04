# zkv

`zkv` is a small key-value store written in Zig. It runs as a REPL, keeps data in memory, and persists mutations to an append-only log file.

## Requirements

- Zig `0.16.0`

## Run

```sh
zig build run
```

## Commands

```text
put <key> <value>  store value under key
get <key>          print value for key
del <key>          delete key
count              print number of keys
help               show help
exit               quit
```

Keys are single tokens and cannot contain whitespace. Values are stored as the rest of the line, so spaces are allowed:

```text
put greeting hello world
get greeting
```

## Persistence

`zkv` writes successful mutations to `zkv.log` in the current working directory:

```text
put name ashish
del name
```

On startup, the log is replayed into the in-memory engine before the REPL starts. Reads and non-mutating commands are not written to the log.

The log format is intentionally simple for now. It assumes keys do not contain whitespace and values do not contain newlines.

## Test

```sh
zig build test
```

## Project Structure

```text
src/engine.zig  in-memory key-value engine
src/parser.zig  REPL command parser
src/log.zig     append-only log and replay
src/repl.zig    REPL loop and command execution
src/main.zig    application entrypoint
```
