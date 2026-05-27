// Unified C import for the daemon — use as: const c = @import("c.zig").lib;
// NER/tokenizer/ONNX headers are NOT included here; they belong to the
// icarium-indexer-codebert plugin binary, not the daemon.
pub const lib = @cImport({
    @cInclude("db.h");
    @cInclude("validate.h");
});
