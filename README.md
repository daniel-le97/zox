# zox

zox is a small Lox interpreter written in Zig 0.16.

## What it supports

- Variables and assignment
- Arithmetic, comparison, equality, and logical operators
- `if`, `while`, and `for`
- Lexical scoping
- Functions and closures
- Classes, instances, methods, inheritance, and `super`
- Simple module/import support

## Run It

Run a `.lox` file with:

```sh
zig build run -- tests/variables.lox
```

## Test It

Run the full test suite with:

```sh
zig build test
```

## Example

```lox
print "hello from zox";
```

## Import Example

```lox
import "support/math.lox";

print math.square(3);
print math.answer;
```
