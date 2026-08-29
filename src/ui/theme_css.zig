//! CSS variable parser for kelpie (#14): extracts `--name: value;` declarations
//! from a CSS string. No GTK dependency — pure text parsing.
//! Territory: ui-builder. See roadmap/designs/14-tokens-color.md.
const std = @import("std");

/// A single CSS variable declaration: `--name: value;`
pub const CssVar = struct {
    name: []const u8,
    value: []const u8,
};

/// Iterator over CSS variable declarations in a string.
/// Parses `--name: value;` patterns, skipping comments and non-variable rules.
pub const Iterator = struct {
    css: []const u8,
    pos: usize,

    /// Returns the next CSS variable declaration, or null if no more found.
    pub fn next(self: *Iterator) ?CssVar {
        while (self.pos < self.css.len) {
            // Skip whitespace
            while (self.pos < self.css.len and std.mem.indexOfScalar(u8, " \t\n\r", self.css[self.pos]) != null) {
                self.pos += 1;
            }

            if (self.pos >= self.css.len) return null;

            // Skip comments /* ... */
            if (self.pos + 1 < self.css.len and self.css[self.pos] == '/' and self.css[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.css.len) {
                    if (self.css[self.pos] == '*' and self.css[self.pos + 1] == '/') {
                        self.pos += 2;
                        break;
                    }
                    self.pos += 1;
                }
                continue;
            }

            // Look for --name: value;
            if (self.pos + 1 < self.css.len and self.css[self.pos] == '-' and self.css[self.pos + 1] == '-') {
                // Found start of variable declaration
                const name_start = self.pos;
                self.pos += 2; // skip --

                // Find the colon
                const colon_pos = std.mem.indexOfScalarPos(u8, self.css, self.pos, ':') orelse {
                    // No colon found, skip to next line
                    self.pos = std.mem.indexOfScalarPos(u8, self.css, self.pos, '\n') orelse self.css.len;
                    continue;
                };

                // Extract name (trim whitespace)
                const name_raw = self.css[name_start..colon_pos];
                const name = std.mem.trim(u8, name_raw, " \t");

                // Skip colon and whitespace
                self.pos = colon_pos + 1;
                while (self.pos < self.css.len and std.mem.indexOfScalar(u8, " \t", self.css[self.pos]) != null) {
                    self.pos += 1;
                }

                // Find the semicolon (or end of line)
                const value_start = self.pos;
                const semi_pos = std.mem.indexOfScalarPos(u8, self.css, self.pos, ';') orelse {
                    // No semicolon, use end of line or end of string
                    const line_end = std.mem.indexOfScalarPos(u8, self.css, self.pos, '\n') orelse self.css.len;
                    self.pos = line_end;
                    const value = std.mem.trim(u8, self.css[value_start..line_end], " \t\r");
                    return CssVar{ .name = name, .value = value };
                };

                // Extract value (trim whitespace)
                const value_raw = self.css[value_start..semi_pos];
                const value = std.mem.trim(u8, value_raw, " \t");

                self.pos = semi_pos + 1; // skip semicolon

                return CssVar{ .name = name, .value = value };
            }

            // Not a variable declaration, skip to next line
            self.pos = std.mem.indexOfScalarPos(u8, self.css, self.pos, '\n') orelse self.css.len;
        }

        return null;
    }
};

/// Creates an iterator over CSS variable declarations in the given string.
pub fn iterate(css: []const u8) Iterator {
    return Iterator{ .css = css, .pos = 0 };
}

test "iterate extracts single variable" {
    const css = "--my-color: rgb(255, 0, 0);";
    var it = iterate(css);
    const v = it.next().?;
    try std.testing.expectEqualStrings("--my-color", v.name);
    try std.testing.expectEqualStrings("rgb(255, 0, 0)", v.value);
    try std.testing.expect(it.next() == null);
}

test "iterate extracts multiple variables" {
    const css =
        "--color1: teal;\n" ++
        "--color2: coral;\n" ++
        "--color3: slateblue;\n";
    var it = iterate(css);

    const v1 = it.next().?;
    try std.testing.expectEqualStrings("--color1", v1.name);
    try std.testing.expectEqualStrings("teal", v1.value);

    const v2 = it.next().?;
    try std.testing.expectEqualStrings("--color2", v2.name);
    try std.testing.expectEqualStrings("coral", v2.value);

    const v3 = it.next().?;
    try std.testing.expectEqualStrings("--color3", v3.name);
    try std.testing.expectEqualStrings("slateblue", v3.value);

    try std.testing.expect(it.next() == null);
}

test "iterate handles irregular whitespace" {
    const css = "  --spaced :  value  ;  ";
    var it = iterate(css);
    const v = it.next().?;
    try std.testing.expectEqualStrings("--spaced", v.name);
    try std.testing.expectEqualStrings("value", v.value);
    try std.testing.expect(it.next() == null);
}

test "iterate handles alpha function as value" {
    const css = "--wash: alpha(accent, 0.12);";
    var it = iterate(css);
    const v = it.next().?;
    try std.testing.expectEqualStrings("--wash", v.name);
    try std.testing.expectEqualStrings("alpha(accent, 0.12)", v.value);
    try std.testing.expect(it.next() == null);
}

test "iterate skips comments" {
    const css =
        "/* this is a comment */\n" ++
        "--color: teal;\n" ++
        "/* another comment */\n" ++
        "--other: coral;\n";
    var it = iterate(css);

    const v1 = it.next().?;
    try std.testing.expectEqualStrings("--color", v1.name);
    try std.testing.expectEqualStrings("teal", v1.value);

    const v2 = it.next().?;
    try std.testing.expectEqualStrings("--other", v2.name);
    try std.testing.expectEqualStrings("coral", v2.value);

    try std.testing.expect(it.next() == null);
}

test "iterate skips non-variable rules" {
    const css =
        ".kelpie-headerbar { min-height: 42px; }\n" ++
        "--my-var: hello;\n" ++
        "body { color: red; }\n";
    var it = iterate(css);

    const v = it.next().?;
    try std.testing.expectEqualStrings("--my-var", v.name);
    try std.testing.expectEqualStrings("hello", v.value);

    try std.testing.expect(it.next() == null);
}

test "iterate handles empty input" {
    const css = "";
    var it = iterate(css);
    try std.testing.expect(it.next() == null);
}

test "iterate handles value without semicolon at end" {
    const css = "--no-semi: value";
    var it = iterate(css);
    const v = it.next().?;
    try std.testing.expectEqualStrings("--no-semi", v.name);
    try std.testing.expectEqualStrings("value", v.value);
    try std.testing.expect(it.next() == null);
}
