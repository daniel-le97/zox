const token = @import("token.zig");

pub const LiteralValue = token.LiteralValue;

pub const Expr = union(enum) {
    literal: LiteralValue,
    grouping: *Expr,
    unary: Unary,
    binary: Binary,
    logical: Logical,
    variable: []const u8,
    assign: Assign,
    call: Call,
    get: Get,
    set: Set,
    super_expr: SuperExpr,
};

pub const Unary = struct {
    operator: token.TokenType,
    right: *Expr,
};

pub const Binary = struct {
    left: *Expr,
    operator: token.TokenType,
    right: *Expr,
};

pub const Logical = struct {
    left: *Expr,
    operator: token.TokenType,
    right: *Expr,
};

pub const Assign = struct {
    name: []const u8,
    value: *Expr,
};

pub const Call = struct {
    callee: *Expr,
    paren: token.Token,
    arguments: []const *Expr,
};

pub const Get = struct {
    object: *Expr,
    name: []const u8,
};

pub const Set = struct {
    object: *Expr,
    name: []const u8,
    value: *Expr,
};

pub const SuperExpr = struct {
    keyword: token.Token,
    method: []const u8,
};

pub const Stmt = union(enum) {
    expression: *Expr,
    print: *Expr,
    var_decl: VarDecl,
    module_decl: ModuleDecl,
    import_stmt: ImportStmt,
    function: FunctionStmt,
    return_stmt: ReturnStmt,
    class_decl: ClassDecl,
    block: []const *Stmt,
    if_stmt: IfStmt,
    while_stmt: WhileStmt,
};

pub const VarDecl = struct {
    name: []const u8,
    initializer: ?*Expr,
};

pub const ModuleDecl = struct {
    name: []const u8,
};

pub const ImportStmt = struct {
    path: []const u8,
    alias: ?[]const u8,
};

pub const IfStmt = struct {
    condition: *Expr,
    then_branch: *Stmt,
    else_branch: ?*Stmt,
};

pub const WhileStmt = struct {
    condition: *Expr,
    body: *Stmt,
};

pub const FunctionStmt = struct {
    name: []const u8,
    params: []const []const u8,
    body: []const *Stmt,
};

pub const ReturnStmt = struct {
    keyword: token.Token,
    value: ?*Expr,
};

pub const ClassDecl = struct {
    name: []const u8,
    superclass: ?[]const u8,
    methods: []const *Stmt,
};
