const std = @import("std");
const ast = @import("../glsl/ast.zig");
const types = @import("../glsl/types.zig");
const builtins = @import("../glsl/builtins.zig");
const diag = @import("../diag.zig");
const code_writer = @import("code.zig");

pub const Error = error{ InvalidShader, OutOfMemory };

const BuiltinUse = struct {
    gl_position: bool = false,
    gl_frag_coord: bool = false,
    gl_front_facing: bool = false,
    gl_vertex_id: bool = false,
    gl_instance_id: bool = false,
    gl_frag_depth: bool = false,
    gl_frag_color: bool = false,
    discard: bool = false,
};

const GlobalKind = enum { uniform, const_, stage_in, stage_out, plain };

const Global = struct {
    name: []const u8,
    typ: types.Type,
    array_len: ?u32,
    kind: GlobalKind,
    decl: *ast.VarDecl,
};

const IoVar = struct {
    name: []const u8,
    typ: types.Type,
    semantic: []const u8,
    interpolation: ?ast.Interpolation = null,
};

const Local = struct {
    name: []const u8,
    typ: types.Type,
};

const Emitter = struct {
    allocator: std.mem.Allocator,
    diagnostics: *diag.Diagnostics,
    stage: ast.Stage,
    unit: *ast.TranslationUnit,
    code: code_writer.Code,

    structs: std.ArrayList(*ast.StructDecl) = .empty,
    functions: std.ArrayList(*ast.Function) = .empty,
    globals: std.ArrayList(Global) = .empty,
    locals: std.ArrayList(Local) = .empty,

    inputs: std.ArrayList(IoVar) = .empty,
    outputs: std.ArrayList(IoVar) = .empty,

    entry: ?*ast.Function = null,
    use: BuiltinUse = .{},
    uses_mod: bool = false,
    in_entry: bool = false,

    fn run(self: *Emitter) Error![]const u8 {
        try self.collect();
        try self.validate();
        try self.buildIo();
        try self.emitTranslationUnit();
        return self.code.buf.toOwnedSlice(self.allocator);
    }

    fn collect(self: *Emitter) Error!void {
        for (self.unit.decls) |decl| {
            switch (decl.*) {
                .struct_decl => |s| try self.structs.append(self.allocator, s),
                .function => |f| {
                    if (std.mem.eql(u8, f.name, "main")) {
                        if (self.entry != null) {
                            return self.fail(f.line, f.column, "multiple definitions of 'main'", .{});
                        }
                        if (f.body == null) {
                            return self.fail(f.line, f.column, "main must have a body", .{});
                        }
                        self.entry = f;
                    } else if (f.body != null) {
                        for (self.functions.items) |existing| {
                            if (std.mem.eql(u8, existing.name, f.name)) {
                                return self.fail(f.line, f.column, "function overloading is not supported ('{s}')", .{f.name});
                            }
                        }
                        try self.functions.append(self.allocator, f);
                    }
                },
                .var_decl => |v| try self.collectGlobal(v),
                .precision => {},
            }
        }
        if (self.entry == null) {
            return self.fail(1, 1, "shader has no 'main' function", .{});
        }
        for (self.unit.decls) |decl| {
            switch (decl.*) {
                .function => |f| {
                    if (f.body) |body| try self.scanStmt(body);
                },
                else => {},
            }
        }
    }

    fn collectGlobal(self: *Emitter, decl: *ast.VarDecl) Error!void {
        const storage = decl.qualifiers.storage orelse {
            const typ = self.resolveType(decl.typ);
            try self.globals.append(self.allocator, .{
                .name = decl.name,
                .typ = typ,
                .array_len = try self.arrayLen(decl.array_len, decl.line, decl.column),
                .kind = .plain,
                .decl = decl,
            });
            return;
        };
        const kind: GlobalKind = switch (storage) {
            .uniform => .uniform,
            .const_ => .const_,
            .in, .attribute => .stage_in,
            .out => .stage_out,
            .varying => if (self.stage == .vertex) .stage_out else .stage_in,
            .buffer, .shared => return self.fail(decl.line, decl.column, "storage qualifier is not supported in this stage", .{}),
            .inout => return self.fail(decl.line, decl.column, "'inout' is not valid on a global variable", .{}),
        };
        if (self.stage == .fragment and storage == .attribute) {
            return self.fail(decl.line, decl.column, "'attribute' is only valid in vertex shaders", .{});
        }
        if (self.stage == .vertex and storage == .varying) {
            return self.fail(decl.line, decl.column, "'varying' is not supported; use 'in'/'out'", .{});
        }
        for (self.globals.items) |existing| {
            if (std.mem.eql(u8, existing.name, decl.name)) {
                return self.fail(decl.line, decl.column, "global '{s}' is declared more than once", .{decl.name});
            }
        }
        const typ = self.resolveType(decl.typ);
        try self.globals.append(self.allocator, .{
            .name = decl.name,
            .typ = typ,
            .array_len = try self.arrayLen(decl.array_len, decl.line, decl.column),
            .kind = kind,
            .decl = decl,
        });
    }

    fn validate(self: *Emitter) Error!void {
        if (self.stage == .vertex) {
            if (self.use.gl_frag_coord or self.use.gl_front_facing or
                self.use.gl_frag_color or self.use.gl_frag_depth)
            {
                return self.fail(1, 1, "fragment shader built-in used in a vertex shader", .{});
            }
            if (!self.use.gl_position) {
                return self.fail(1, 1, "vertex shader does not write gl_Position", .{});
            }
            if (self.use.discard) {
                return self.fail(1, 1, "discard is not allowed in a vertex shader", .{});
            }
        } else {
            if (self.use.gl_position or self.use.gl_vertex_id or self.use.gl_instance_id) {
                return self.fail(1, 1, "vertex shader built-in used in a fragment shader", .{});
            }
        }
        if (self.stage == .fragment and self.use.gl_frag_color) {
            for (self.globals.items) |global| {
                if (global.kind == .stage_out) {
                    return self.fail(1, 1, "gl_FragColor cannot be combined with declared fragment outputs", .{});
                }
            }
        }
        for (self.functions.items) |function| {
            for (function.params) |param| {
                if (self.resolveType(param.typ).isSampler()) {
                    return self.fail(function.line, function.column, "sampler parameters are not supported", .{});
                }
            }
            if (function.body) |body| {
                if (self.stmtUsesBuiltin(body)) {
                    return self.fail(function.line, function.column, "stage built-ins may only be used in 'main'", .{});
                }
                for (self.globals.items) |global| {
                    if (global.kind == .stage_in or global.kind == .stage_out) {
                        if (self.stmtUsesName(body, global.name)) {
                            return self.fail(function.line, function.column, "stage variable '{s}' cannot be used outside 'main'", .{global.name});
                        }
                    }
                }
            }
        }
        for (self.globals.items) |global| {
            if (global.kind == .stage_in or global.kind == .stage_out) {
                if (global.array_len != null) {
                    return self.fail(global.decl.line, global.decl.column, "array stage inputs and outputs are not supported", .{});
                }
                if (global.typ == .named) {
                    return self.fail(global.decl.line, global.decl.column, "struct stage inputs and outputs are not supported", .{});
                }
            }
            if (global.kind == .uniform and global.typ.isSampler()) {
                if (global.array_len != null) {
                    return self.fail(global.decl.line, global.decl.column, "sampler arrays are not supported", .{});
                }
                if (global.typ.sampler.isShadow()) {
                    return self.fail(global.decl.line, global.decl.column, "shadow samplers are not supported", .{});
                }
                if (global.typ.sampler.isArray()) {
                    return self.fail(global.decl.line, global.decl.column, "array samplers are not supported", .{});
                }
            }
            if (global.kind == .uniform and global.decl.initializer != null) {
                return self.fail(global.decl.line, global.decl.column, "uniform initializers are not supported", .{});
            }
            if (global.kind == .const_ and global.decl.initializer == null) {
                return self.fail(global.decl.line, global.decl.column, "const global '{s}' requires an initializer", .{global.name});
            }
        }
    }

    fn buildIo(self: *Emitter) Error!void {
        var texcoord: u32 = 0;
        var target: u32 = 0;
        for (self.globals.items) |global| {
            switch (global.kind) {
                .stage_in => try self.inputs.append(self.allocator, .{
                    .name = global.name,
                    .typ = global.typ,
                    .semantic = try self.inputSemantic(global, &texcoord),
                    .interpolation = if (self.stage == .fragment) global.decl.qualifiers.interpolation else null,
                }),
                .stage_out => try self.outputs.append(self.allocator, .{
                    .name = global.name,
                    .typ = global.typ,
                    .semantic = try self.outputSemantic(global, &target, &texcoord),
                    .interpolation = null,
                }),
                else => {},
            }
        }
        if (self.stage == .vertex) {
            try self.outputs.insert(self.allocator, 0, .{
                .name = "gl_position",
                .typ = .{ .vector = .{ .scalar = .float, .len = 4 } },
                .semantic = "SV_Position",
            });
            if (self.use.gl_vertex_id) {
                try self.inputs.append(self.allocator, .{
                    .name = "gl_vertex_id",
                    .typ = .{ .scalar = .uint },
                    .semantic = "SV_VertexID",
                });
            }
            if (self.use.gl_instance_id) {
                try self.inputs.append(self.allocator, .{
                    .name = "gl_instance_id",
                    .typ = .{ .scalar = .uint },
                    .semantic = "SV_InstanceID",
                });
            }
        } else {
            if (self.use.gl_frag_coord) {
                try self.inputs.append(self.allocator, .{
                    .name = "gl_frag_coord",
                    .typ = .{ .vector = .{ .scalar = .float, .len = 4 } },
                    .semantic = "SV_Position",
                });
            }
            if (self.use.gl_front_facing) {
                try self.inputs.append(self.allocator, .{
                    .name = "gl_front_facing",
                    .typ = .{ .scalar = .bool },
                    .semantic = "SV_IsFrontFace",
                });
            }
            if (self.use.gl_frag_color) {
                try self.outputs.append(self.allocator, .{
                    .name = "gl_frag_color",
                    .typ = .{ .vector = .{ .scalar = .float, .len = 4 } },
                    .semantic = "SV_Target0",
                });
            }
            if (self.use.gl_frag_depth) {
                try self.outputs.append(self.allocator, .{
                    .name = "gl_frag_depth",
                    .typ = .{ .scalar = .float },
                    .semantic = "SV_Depth",
                });
            }
        }
    }

    fn inputSemantic(self: *Emitter, global: Global, texcoord: *u32) Error![]const u8 {
        if (self.stage == .fragment) {
            const location = layoutValue(global.decl.qualifiers, "location");
            if (location) |index| return std.fmt.allocPrint(self.allocator, "TEXCOORD{d}", .{index});
            const semantic = try std.fmt.allocPrint(self.allocator, "TEXCOORD{d}", .{texcoord.*});
            texcoord.* += 1;
            return semantic;
        }
        const lower = try std.ascii.allocLowerString(self.allocator, global.name);
        if (std.mem.indexOf(u8, lower, "position") != null) return "POSITION";
        if (std.mem.indexOf(u8, lower, "normal") != null) return "NORMAL";
        if (std.mem.indexOf(u8, lower, "tangent") != null) return "TANGENT";
        if (std.mem.indexOf(u8, lower, "bitangent") != null) return "BINORMAL";
        if (std.mem.indexOf(u8, lower, "binormal") != null) return "BINORMAL";
        if (std.mem.indexOf(u8, lower, "color") != null or std.mem.indexOf(u8, lower, "colour") != null) return "COLOR";
        if (std.mem.indexOf(u8, lower, "weight") != null) return "BLENDWEIGHT";
        if (std.mem.indexOf(u8, lower, "joint") != null) return "BLENDINDICES";
        if (std.mem.indexOf(u8, lower, "index") != null) return "BLENDINDICES";
        if (layoutValue(global.decl.qualifiers, "location")) |index| {
            return std.fmt.allocPrint(self.allocator, "TEXCOORD{d}", .{index});
        }
        const semantic = try std.fmt.allocPrint(self.allocator, "TEXCOORD{d}", .{texcoord.*});
        texcoord.* += 1;
        return semantic;
    }

    fn outputSemantic(self: *Emitter, global: Global, target: *u32, texcoord: *u32) Error![]const u8 {
        const location = layoutValue(global.decl.qualifiers, "location");
        if (self.stage == .vertex) {
            if (location) |index| return std.fmt.allocPrint(self.allocator, "TEXCOORD{d}", .{index});
            const semantic = try std.fmt.allocPrint(self.allocator, "TEXCOORD{d}", .{texcoord.*});
            texcoord.* += 1;
            return semantic;
        }
        if (location) |index| return std.fmt.allocPrint(self.allocator, "SV_Target{d}", .{index});
        const semantic = try std.fmt.allocPrint(self.allocator, "SV_Target{d}", .{target.*});
        target.* += 1;
        return semantic;
    }

    fn emitTranslationUnit(self: *Emitter) Error!void {
        try self.emitStructs();
        try self.emitGlobals();
        try self.emitIoStructs();
        try self.emitHelpers();
        try self.emitFunctions();
        try self.emitEntry();
    }

    fn emitStructs(self: *Emitter) Error!void {
        for (self.structs.items) |s| {
            try self.code.printLine("struct {s} {{", .{s.name});
            self.code.push();
            for (s.fields) |field| {
                const typ = self.resolveType(field.typ);
                try self.emitType(typ);
                try self.code.print(" {s}", .{field.name});
                if (field.array_len) |len| try self.code.print("[{d}]", .{len});
                try self.code.line(";");
            }
            self.code.pop();
            try self.code.line("};");
            try self.code.blank();
        }
    }

    fn emitGlobals(self: *Emitter) Error!void {
        var has_const = false;
        for (self.globals.items) |global| {
            if (global.kind != .const_ and global.kind != .plain) continue;
            has_const = true;
            try self.code.write("static ");
            if (global.kind == .const_) try self.code.write("const ");
            try self.emitType(global.typ);
            try self.code.print(" {s}", .{global.name});
            if (global.array_len) |len| try self.code.print("[{d}]", .{len});
            if (global.decl.initializer) |initializer| {
                try self.code.write(" = ");
                try self.emitExprPrec(initializer, 1);
            }
            try self.code.line(";");
        }
        if (has_const) try self.code.blank();

        var uniform_count: usize = 0;
        for (self.globals.items) |global| {
            if (global.kind == .uniform and !global.typ.isSampler()) uniform_count += 1;
        }
        if (uniform_count > 0) {
            try self.code.line("cbuffer Globals : register(b0)");
            try self.code.line("{");
            self.code.push();
            for (self.globals.items) |global| {
                if (global.kind != .uniform or global.typ.isSampler()) continue;
                try self.emitType(global.typ);
                try self.code.print(" {s}", .{global.name});
                if (global.array_len) |len| try self.code.print("[{d}]", .{len});
                try self.code.line(";");
            }
            self.code.pop();
            try self.code.line("};");
            try self.code.blank();
        }

        var texture: u32 = 0;
        var sampler: u32 = 0;
        for (self.globals.items) |global| {
            if (global.kind != .uniform) continue;
            const sampler_kind = switch (global.typ) {
                .sampler => |kind| kind,
                else => continue,
            };
            try self.code.print("{s}<{s}> {s} : register(t{d});", .{
                samplerObjectType(sampler_kind),
                samplerElementType(sampler_kind),
                global.name,
                texture,
            });
            try self.code.blank();
            if (!sampler_kind.isBuffer()) {
                try self.code.printLine("SamplerState {s}_sampler : register(s{d});", .{ global.name, sampler });
                try self.code.blank();
                sampler += 1;
            }
            texture += 1;
        }
    }

    fn emitIoStructs(self: *Emitter) Error!void {
        if (self.inputs.items.len > 0) {
            try self.emitIoStruct(self.stageInputName(), self.inputs.items);
        }
        if (self.outputs.items.len > 0) {
            try self.emitIoStruct(self.stageOutputName(), self.outputs.items);
        }
    }

    fn emitIoStruct(self: *Emitter, name: []const u8, fields: []const IoVar) Error!void {
        try self.code.printLine("struct {s} {{", .{name});
        self.code.push();
        for (fields) |field| {
            if (field.interpolation) |interpolation| {
                switch (interpolation) {
                    .flat => try self.code.write("nointerpolation "),
                    .noperspective => try self.code.write("noperspective "),
                    .smooth => {},
                }
            }
            try self.emitType(field.typ);
            try self.code.print(" {s} : {s};", .{ field.name, field.semantic });
            try self.code.blank();
        }
        self.code.pop();
        try self.code.line("};");
        try self.code.blank();
    }

    fn stageInputName(self: *Emitter) []const u8 {
        return if (self.stage == .vertex) "VSInput" else "PSInput";
    }

    fn stageOutputName(self: *Emitter) []const u8 {
        return if (self.stage == .vertex) "VSOutput" else "PSOutput";
    }

    fn emitHelpers(self: *Emitter) Error!void {
        if (!self.uses_mod) return;
        const scalar_names = [_][]const u8{ "float", "float2", "float3", "float4" };
        for (scalar_names) |type_name| {
            try self.code.printLine("{s} glsl_mod({s} x, {s} y) {{", .{ type_name, type_name, type_name });
            self.code.push();
            try self.code.line("return x - y * floor(x / y);");
            self.code.pop();
            try self.code.line("}");
            try self.code.blank();
        }
        for (scalar_names[1..]) |type_name| {
            try self.code.printLine("{s} glsl_mod({s} x, float y) {{", .{ type_name, type_name });
            self.code.push();
            try self.code.line("return x - y * floor(x / y);");
            self.code.pop();
            try self.code.line("}");
            try self.code.blank();
        }
    }

    fn emitFunctions(self: *Emitter) Error!void {
        for (self.functions.items) |function| {
            if (function.body == null) continue;
            try self.emitFunction(function);
            try self.code.blank();
        }
    }

    fn emitFunction(self: *Emitter, function: *ast.Function) Error!void {
        const mark = self.locals.items.len;
        defer self.locals.shrinkRetainingCapacity(mark);
        try self.emitTypeName(function.return_type);
        try self.code.print(" {s}(", .{function.name});
        for (function.params, 0..) |param, index| {
            if (index > 0) try self.code.write(", ");
            try self.emitParameter(param, true);
        }
        try self.code.line(")");
        try self.code.line("{");
        self.code.push();
        for (function.params) |param| {
            if (param.name) |name| {
                try self.locals.append(self.allocator, .{ .name = name, .typ = self.paramType(param) });
            }
        }
        try self.emitBody(function.body.?);
        self.code.pop();
        try self.code.line("}");
    }

    fn emitEntry(self: *Emitter) Error!void {
        const entry = self.entry.?;
        self.in_entry = true;
        defer self.in_entry = false;
        const has_output = self.outputs.items.len > 0;
        if (has_output) {
            try self.code.print("{s} main(", .{self.stageOutputName()});
        } else {
            try self.code.write("void main(");
        }
        if (self.inputs.items.len > 0) {
            try self.code.print("{s} input", .{self.stageInputName()});
        }
        try self.code.line(")");
        try self.code.line("{");
        self.code.push();
        if (has_output) {
            try self.code.printLine("{s} output;", .{self.stageOutputName()});
            try self.locals.append(self.allocator, .{
                .name = "output",
                .typ = .{ .named = self.stageOutputName() },
            });
        }
        try self.emitBody(entry.body.?);
        if (has_output) try self.code.line("return output;");
        self.code.pop();
        try self.code.line("}");
    }

    fn emitBody(self: *Emitter, body: *ast.Stmt) Error!void {
        switch (body.*) {
            .block => |block| {
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                for (block.statements) |statement| try self.emitStmt(statement);
            },
            else => try self.emitStmt(body),
        }
    }

    fn emitParameter(self: *Emitter, param: ast.Parameter, with_name: bool) Error!void {
        switch (param.direction) {
            .in => {},
            .out => try self.code.write("out "),
            .inout => try self.code.write("inout "),
        }
        try self.emitTypeName(param.typ);
        if (with_name) {
            if (param.name) |name| try self.code.print(" {s}", .{name});
        }
        if (param.array_len) |expression| {
            const len = self.constInt(expression) orelse
                return self.fail(expression.line(), 1, "parameter array length must be a constant integer", .{});
            try self.code.print("[{d}]", .{len});
        }
    }

    fn emitStmt(self: *Emitter, statement: *ast.Stmt) Error!void {
        switch (statement.*) {
            .block => |block| {
                try self.code.line("{");
                self.code.push();
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                for (block.statements) |child| try self.emitStmt(child);
                self.code.pop();
                try self.code.line("}");
            },
            .expr => |expression| {
                try self.emitExprPrec(expression, 0);
                try self.code.line(";");
            },
            .decl => |variables| {
                for (variables, 0..) |variable, index| {
                    if (index > 0) try self.code.write(", ");
                    try self.emitLocalDecl(variable);
                }
                try self.code.line(";");
            },
            .if_stmt => |if_stmt| {
                try self.code.write("if (");
                try self.emitExprPrec(if_stmt.condition, 0);
                try self.code.line(")");
                try self.emitBranch(if_stmt.then_branch);
                if (if_stmt.else_branch) |else_branch| {
                    try self.code.line("else");
                    try self.emitBranch(else_branch);
                }
            },
            .for_stmt => |for_stmt| {
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                try self.code.write("for (");
                if (for_stmt.init) |init| {
                    switch (init.*) {
                        .decl => |variables| {
                            for (variables, 0..) |variable, index| {
                                if (index > 0) try self.code.write(", ");
                                try self.emitLocalDecl(variable);
                            }
                        },
                        .expr => |expression| try self.emitExprPrec(expression, 0),
                        else => {},
                    }
                }
                try self.code.write("; ");
                if (for_stmt.condition) |condition| try self.emitExprPrec(condition, 0);
                try self.code.write("; ");
                if (for_stmt.increment) |increment| try self.emitExprPrec(increment, 0);
                try self.code.line(")");
                try self.emitBranch(for_stmt.body);
            },
            .while_stmt => |while_stmt| {
                try self.code.write("while (");
                try self.emitExprPrec(while_stmt.condition, 0);
                try self.code.line(")");
                try self.emitBranch(while_stmt.body);
            },
            .do_while => |do_while| {
                try self.code.line("do");
                try self.emitBranch(do_while.body);
                try self.code.write("while (");
                try self.emitExprPrec(do_while.condition, 0);
                try self.code.line(");");
            },
            .switch_stmt => |switch_stmt| {
                try self.code.write("switch (");
                try self.emitExprPrec(switch_stmt.expression, 0);
                try self.code.line(")");
                switch (switch_stmt.body.*) {
                    .block => |block| {
                        try self.code.line("{");
                        self.code.push();
                        var body_open = false;
                        for (block.statements) |child| {
                            switch (child.*) {
                                .case_label, .default_label => {
                                    if (body_open) self.code.pop();
                                    try self.emitStmt(child);
                                    self.code.push();
                                    body_open = true;
                                },
                                else => try self.emitStmt(child),
                            }
                        }
                        if (body_open) self.code.pop();
                        self.code.pop();
                        try self.code.line("}");
                    },
                    else => try self.emitBranch(switch_stmt.body),
                }
            },
            .return_stmt => |return_stmt| {
                if (self.in_entry) {
                    if (return_stmt.value != null) {
                        return self.fail(return_stmt.line, 1, "'main' must not return a value", .{});
                    }
                    if (self.outputs.items.len > 0) {
                        try self.code.line("return output;");
                    } else {
                        try self.code.line("return;");
                    }
                } else if (return_stmt.value) |value| {
                    try self.code.write("return ");
                    try self.emitExprPrec(value, 0);
                    try self.code.line(";");
                } else {
                    try self.code.line("return;");
                }
            },
            .break_stmt => try self.code.line("break;"),
            .continue_stmt => try self.code.line("continue;"),
            .discard_stmt => try self.code.line("discard;"),
            .case_label => |label| {
                try self.code.write("case ");
                try self.emitExprPrec(label.value, 0);
                try self.code.line(":");
            },
            .default_label => try self.code.line("default:"),
        }
    }

    fn emitBranch(self: *Emitter, branch: *ast.Stmt) Error!void {
        switch (branch.*) {
            .block => try self.emitStmt(branch),
            else => {
                try self.code.line("{");
                self.code.push();
                const mark = self.locals.items.len;
                defer self.locals.shrinkRetainingCapacity(mark);
                try self.emitStmt(branch);
                self.code.pop();
                try self.code.line("}");
            },
        }
    }

    fn emitLocalDecl(self: *Emitter, variable: *ast.VarDecl) Error!void {
        if (variable.qualifiers.storage) |storage| {
            if (storage == .const_) try self.code.write("const ");
        }
        const typ = self.resolveType(variable.typ);
        try self.emitType(typ);
        try self.code.print(" {s}", .{variable.name});
        var local_type = typ;
        if (try self.arrayLen(variable.array_len, variable.line, variable.column)) |len| {
            try self.code.print("[{d}]", .{len});
            local_type = .{ .array = .{
                .elem = try self.allocType(typ),
                .len = len,
            } };
        }
        if (variable.initializer) |initializer| {
            try self.code.write(" = ");
            try self.emitExprPrec(initializer, 1);
        }
        try self.locals.append(self.allocator, .{ .name = variable.name, .typ = local_type });
    }

    fn emitTypeName(self: *Emitter, name: ast.TypeName) Error!void {
        try self.emitType(self.resolveType(name));
    }

    fn emitType(self: *Emitter, typ: types.Type) Error!void {
        switch (typ) {
            .named => |name| try self.code.print("{s}", .{name}),
            .array => |array| try self.emitType(array.elem.*),
            else => try self.code.print("{s}", .{try types.hlslName(self.allocator, typ)}),
        }
    }

    fn emitExprPrec(self: *Emitter, expression: *ast.Expr, min_precedence: u8) Error!void {
        const precedence = exprPrecedence(expression);
        const parenthesize = precedence < min_precedence;
        if (parenthesize) try self.code.write("(");
        try self.emitExpr(expression);
        if (parenthesize) try self.code.write(")");
    }

    fn emitExpr(self: *Emitter, expression: *ast.Expr) Error!void {
        switch (expression.*) {
            .int_literal => |text| try self.code.write(text),
            .uint_literal => |text| try self.code.write(text),
            .float_literal => |text| try self.emitFloatLiteral(text),
            .bool_literal => |value| try self.code.write(if (value) "true" else "false"),
            .identifier => |ident| {
                if (try self.builtinText(ident.name, ident.line, ident.column)) |text| {
                    try self.code.write(text);
                    return;
                }
                if (self.findLocal(ident.name) != null) {
                    try self.code.write(ident.name);
                    return;
                }
                if (self.findGlobal(ident.name)) |global| {
                    switch (global.kind) {
                        .stage_in => try self.code.print("input.{s}", .{ident.name}),
                        .stage_out => try self.code.print("output.{s}", .{ident.name}),
                        else => try self.code.write(ident.name),
                    }
                    return;
                }
                if (std.mem.eql(u8, ident.name, "gl_FragData")) {
                    return self.fail(ident.line, ident.column, "gl_FragData is not supported", .{});
                }
                return self.fail(ident.line, ident.column, "unknown identifier '{s}'", .{ident.name});
            },
            .unary => |unary| {
                const op = switch (unary.op) {
                    .plus => "+",
                    .minus => "-",
                    .logical_not => "!",
                    .bit_not => "~",
                };
                try self.code.write(op);
                try self.emitExprPrec(unary.operand, 13);
            },
            .postfix => |postfix| {
                try self.emitExprPrec(postfix.operand, 14);
                try self.code.write(if (postfix.increment) "++" else "--");
            },
            .binary => |binary| try self.emitBinary(binary),
            .assign => |assign| {
                const target_type = self.typeOf(assign.target);
                if (assign.op == .multiply and target_type.isMatrix() and self.typeOf(assign.value).isMatrix()) {
                    try self.emitExprPrec(assign.target, 14);
                    try self.code.write(" = mul(");
                    try self.emitExprPrec(assign.target, 14);
                    try self.code.write(", ");
                    try self.emitExprPrec(assign.value, 1);
                    try self.code.write(")");
                } else {
                    try self.emitExprPrec(assign.target, 14);
                    try self.code.print(" {s} ", .{assignOperator(assign.op)});
                    try self.emitExprPrec(assign.value, 1);
                }
            },
            .ternary => |ternary| {
                try self.emitExprPrec(ternary.condition, 3);
                try self.code.write(" ? ");
                try self.emitExprPrec(ternary.then_expr, 1);
                try self.code.write(" : ");
                try self.emitExprPrec(ternary.else_expr, 1);
            },
            .call => |call| try self.emitCall(call),
            .member => |member| {
                try self.emitExprPrec(member.base, 14);
                try self.code.write(".");
                const base = self.typeOf(member.base);
                if ((base.isVector() or base.isScalar()) and swizzleLength(member.name) != null) {
                    try self.emitSwizzle(member.name);
                } else {
                    try self.code.write(member.name);
                }
            },
            .index => |index| {
                if (self.typeOf(index.base).isMatrix()) {
                    return self.fail(index.line, index.column, "matrix indexing is not supported", .{});
                }
                try self.emitExprPrec(index.base, 14);
                try self.code.write("[");
                try self.emitExprPrec(index.index, 0);
                try self.code.write("]");
            },
            .comma => |comma| {
                try self.code.write("(");
                try self.emitExprPrec(comma.left, 0);
                try self.code.write(", ");
                try self.emitExprPrec(comma.right, 0);
                try self.code.write(")");
            },
        }
    }

    fn emitFloatLiteral(self: *Emitter, text: []const u8) Error!void {
        const is_double = std.mem.endsWith(u8, text, "lf") or std.mem.endsWith(u8, text, "LF");
        var end = text.len;
        if (is_double) {
            end -= 2;
        } else if (end > 0 and (text[end - 1] == 'f' or text[end - 1] == 'F')) {
            end -= 1;
        }
        try self.code.write(text[0..end]);
        if (is_double) try self.code.write("L");
    }

    fn emitSwizzle(self: *Emitter, name: []const u8) Error!void {
        for (name) |c| {
            const mapped: u8 = switch (c) {
                'x', 'r', 's' => 'x',
                'y', 'g', 't' => 'y',
                'z', 'b', 'p' => 'z',
                'w', 'a', 'q' => 'w',
                else => c,
            };
            try self.code.write(&[_]u8{mapped});
        }
    }

    fn emitBinary(self: *Emitter, binary: ast.Binary) Error!void {
        if (binary.op == .multiply and self.needsMul(binary.left, binary.right)) {
            try self.code.write("mul(");
            try self.emitExprPrec(binary.left, 1);
            try self.code.write(", ");
            try self.emitExprPrec(binary.right, 1);
            try self.code.write(")");
            return;
        }
        if (binary.op == .logical_xor) {
            try self.emitExprPrec(binary.left, 8);
            try self.code.write(" != ");
            try self.emitExprPrec(binary.right, 9);
            return;
        }
        const precedence = binaryPrecedence(binary.op);
        try self.emitExprPrec(binary.left, precedence);
        try self.code.print(" {s} ", .{binaryOperator(binary.op)});
        try self.emitExprPrec(binary.right, precedence + 1);
    }

    fn needsMul(self: *Emitter, left: *ast.Expr, right: *ast.Expr) bool {
        const left_type = self.typeOf(left);
        const right_type = self.typeOf(right);
        if (left_type.isMatrix() and right_type.isScalar()) return false;
        if (right_type.isMatrix() and left_type.isScalar()) return false;
        return left_type.isMatrix() or right_type.isMatrix();
    }

    fn emitCall(self: *Emitter, call: ast.Call) Error!void {
        if (types.fromBuiltinName(call.callee)) |typ| {
            try self.emitConstructor(call, typ);
            return;
        }
        if (self.findStruct(call.callee) != null) {
            return self.fail(call.line, call.column, "struct constructors are not supported", .{});
        }
        if (self.findFunction(call.callee)) |function| {
            if (function.params.len != call.args.len) {
                return self.fail(call.line, call.column, "function '{s}' expects {d} arguments, got {d}", .{
                    call.callee, function.params.len, call.args.len,
                });
            }
            try self.code.print("{s}(", .{call.callee});
            for (call.args, 0..) |arg, index| {
                if (index > 0) try self.code.write(", ");
                try self.emitExprPrec(arg, 1);
            }
            try self.code.write(")");
            return;
        }
        const intrinsic = builtins.classify(call.callee);
        switch (intrinsic) {
            .passthrough => {
                const name = if (std.mem.eql(u8, call.callee, "atan") and call.args.len == 2) "atan2" else if (std.mem.eql(u8, call.callee, "roundEven")) "round" else call.callee;
                try self.code.print("{s}(", .{name});
                for (call.args, 0..) |arg, index| {
                    if (index > 0) try self.code.write(", ");
                    try self.emitExprPrec(arg, 1);
                }
                try self.code.write(")");
            },
            .mix => {
                if (call.args.len == 3 and isBoolValue(self.typeOf(call.args[2]))) {
                    try self.emitNamedCall("select", &.{ call.args[2], call.args[1], call.args[0] });
                } else {
                    try self.emitNamedCall("lerp", call.args);
                }
            },
            .fract, .inversesqrt, .ddx, .ddy, .fma => {
                try self.emitNamedCall(builtins.hlslName(intrinsic), call.args);
            },
            .atan2 => try self.emitNamedCall("atan2", call.args),
            .mod => {
                self.uses_mod = true;
                try self.emitNamedCall("glsl_mod", call.args);
            },
            .matrix_comp_mult => {
                if (call.args.len != 2) {
                    return self.fail(call.line, call.column, "matrixCompMult expects two arguments", .{});
                }
                try self.emitExprPrec(call.args[0], 12);
                try self.code.write(" * ");
                try self.emitExprPrec(call.args[1], 13);
            },
            .compare => {
                const op = builtins.compareOperator(call.callee).?;
                if (call.args.len != 2) {
                    return self.fail(call.line, call.column, "'{s}' expects two arguments", .{call.callee});
                }
                try self.emitExprPrec(call.args[0], 9);
                try self.code.print(" {s} ", .{op});
                try self.emitExprPrec(call.args[1], 10);
            },
            .logical_not => {
                try self.code.write("!");
                try self.emitExprPrec(call.args[0], 13);
            },
            .texture, .texture_lod, .texture_grad => try self.emitTextureCall(call, intrinsic),
            .texel_fetch => try self.emitTexelFetch(call),
            .unsupported => return self.fail(call.line, call.column, "intrinsic '{s}' is not supported", .{call.callee}),
        }
    }

    fn emitNamedCall(self: *Emitter, name: []const u8, args: []const *ast.Expr) Error!void {
        try self.code.print("{s}(", .{name});
        for (args, 0..) |arg, index| {
            if (index > 0) try self.code.write(", ");
            try self.emitExprPrec(arg, 1);
        }
        try self.code.write(")");
    }

    fn emitConstructor(self: *Emitter, call: ast.Call, typ: types.Type) Error!void {
        switch (typ) {
            .scalar => {
                if (call.args.len != 1) {
                    return self.fail(call.line, call.column, "scalar constructor expects one argument", .{});
                }
                try self.code.print("{s}(", .{try types.hlslName(self.allocator, typ)});
                try self.emitExprPrec(call.args[0], 1);
                try self.code.write(")");
            },
            .vector => |vector| try self.emitVectorConstructor(call, vector),
            .matrix => |matrix| try self.emitMatrixConstructor(call, matrix),
            else => return self.fail(call.line, call.column, "invalid constructor", .{}),
        }
    }

    fn emitVectorConstructor(self: *Emitter, call: ast.Call, vector: types.Type.Vector) Error!void {
        const type_name = try types.hlslName(self.allocator, .{ .vector = vector });
        if (call.args.len == 0) {
            return self.fail(call.line, call.column, "vector constructor requires arguments", .{});
        }
        if (call.args.len == 1) {
            const arg_type = self.typeOf(call.args[0]);
            if (arg_type.isMatrix()) {
                return self.fail(call.line, call.column, "constructing a vector from a matrix is not supported", .{});
            }
            if (arg_type.isVector() and arg_type.vector.len > vector.len) {
                try self.code.write("(");
                try self.emitExprPrec(call.args[0], 0);
                try self.code.print(").{s}", .{swizzlePrefix(vector.len)});
                return;
            }
            try self.code.print("{s}(", .{type_name});
            if (arg_type.isScalar()) {
                var index: u8 = 0;
                while (index < vector.len) : (index += 1) {
                    if (index > 0) try self.code.write(", ");
                    try self.emitExprPrec(call.args[0], 1);
                }
            } else if (arg_type.isVector() and arg_type.vector.len < vector.len) {
                try self.emitExprPrec(call.args[0], 1);
                var index: u8 = arg_type.vector.len;
                while (index < vector.len) : (index += 1) {
                    try self.code.write(", ");
                    const one = index == 3;
                    try self.code.write(scalarLiteral(vector.scalar, one));
                }
            } else {
                try self.emitExprPrec(call.args[0], 1);
            }
            try self.code.write(")");
            return;
        }
        var total: u32 = 0;
        for (call.args) |arg| {
            const arg_type = self.typeOf(arg);
            if (arg_type.isMatrix()) {
                return self.fail(call.line, call.column, "matrix arguments in vector constructors are not supported", .{});
            }
            total += arg_type.componentCount() orelse 1;
        }
        if (total != vector.len) {
            return self.fail(call.line, call.column, "vector constructor has {d} components, expected {d}", .{ total, vector.len });
        }
        try self.code.print("{s}(", .{type_name});
        for (call.args, 0..) |arg, index| {
            if (index > 0) try self.code.write(", ");
            try self.emitExprPrec(arg, 1);
        }
        try self.code.write(")");
    }

    fn emitMatrixConstructor(self: *Emitter, call: ast.Call, matrix: types.Type.Matrix) Error!void {
        const type_name = try types.hlslName(self.allocator, .{ .matrix = matrix });
        if (call.args.len == 1) {
            const arg_type = self.typeOf(call.args[0]);
            switch (arg_type) {
                .scalar => {
                    try self.code.print("{s}(", .{type_name});
                    var r: u32 = 0;
                    while (r < matrix.rows) : (r += 1) {
                        var c: u32 = 0;
                        while (c < matrix.cols) : (c += 1) {
                            if (r != 0 or c != 0) try self.code.write(", ");
                            if (r == c) {
                                try self.emitExprPrec(call.args[0], 1);
                            } else {
                                try self.code.write("0");
                            }
                        }
                    }
                    try self.code.write(")");
                },
                .matrix => |arg_matrix| {
                    if (arg_matrix.cols == matrix.cols and arg_matrix.rows == matrix.rows) {
                        try self.emitExprPrec(call.args[0], 1);
                    } else if (matrix.cols > arg_matrix.cols or matrix.rows > arg_matrix.rows) {
                        return self.fail(call.line, call.column, "matrix construction that enlarges dimensions is not supported", .{});
                    } else {
                        try self.code.print("({s})(", .{type_name});
                        try self.emitExprPrec(call.args[0], 1);
                        try self.code.write(")");
                    }
                },
                else => return self.fail(call.line, call.column, "unsupported matrix constructor argument", .{}),
            }
            return;
        }
        if (call.args.len == @as(usize, matrix.cols)) {
            for (call.args) |arg| {
                const arg_type = self.typeOf(arg);
                if (!arg_type.isVector() or arg_type.vector.len != matrix.rows) {
                    return self.fail(call.line, call.column, "matrix constructor columns must be {d}-component vectors", .{matrix.rows});
                }
            }
            try self.code.print("transpose(float{d}x{d}(", .{ matrix.cols, matrix.rows });
            for (call.args, 0..) |arg, index| {
                if (index > 0) try self.code.write(", ");
                try self.emitExprPrec(arg, 1);
            }
            try self.code.write("))");
            return;
        }
        if (call.args.len == @as(usize, matrix.cols) * matrix.rows) {
            for (call.args) |arg| {
                if (self.typeOf(arg).componentCount() != 1) {
                    return self.fail(call.line, call.column, "matrix constructor mixes scalars and vectors", .{});
                }
            }
            try self.code.print("{s}(", .{type_name});
            var r: u32 = 0;
            var first = true;
            while (r < matrix.rows) : (r += 1) {
                var c: u32 = 0;
                while (c < matrix.cols) : (c += 1) {
                    if (!first) try self.code.write(", ");
                    first = false;
                    const index = c * matrix.rows + r;
                    try self.emitExprPrec(call.args[index], 1);
                }
            }
            try self.code.write(")");
            return;
        }
        return self.fail(call.line, call.column, "matrix constructor has an unsupported number of arguments", .{});
    }

    fn emitTextureCall(self: *Emitter, call: ast.Call, intrinsic: builtins.Intrinsic) Error!void {
        if (call.args.len < 2) {
            return self.fail(call.line, call.column, "'{s}' requires a sampler and coordinates", .{call.callee});
        }
        if (intrinsic == .texture and call.args.len != 2) {
            return self.fail(call.line, call.column, "texture bias is not supported", .{});
        }
        if (self.samplerKindOf(call.args[0]) == null) {
            return self.fail(call.line, call.column, "texture lookup requires a sampler uniform", .{});
        }
        if (self.samplerKindOf(call.args[0]).?.isBuffer()) {
            return self.fail(call.line, call.column, "texture() is not supported for buffer samplers; use texelFetch", .{});
        }
        const object = switch (call.args[0].*) {
            .identifier => |ident| ident.name,
            else => return self.fail(call.line, call.column, "texture lookup requires a sampler identifier", .{}),
        };
        if (intrinsic == .texture_grad and self.stage == .vertex) {
            return self.fail(call.line, call.column, "textureGrad is not supported in vertex shaders", .{});
        }
        const force_level = intrinsic == .texture and self.stage == .vertex;
        const method = if (force_level) "SampleLevel" else builtins.hlslName(intrinsic);
        try self.code.print("{s}.{s}({s}_sampler", .{ object, method, object });
        for (call.args[1..]) |arg| {
            try self.code.write(", ");
            try self.emitExprPrec(arg, 1);
        }
        if (force_level) try self.code.write(", 0.0");
        try self.code.write(")");
    }

    fn emitTexelFetch(self: *Emitter, call: ast.Call) Error!void {
        if (call.args.len != 3) {
            return self.fail(call.line, call.column, "texelFetch expects a sampler, coordinates, and a level", .{});
        }
        const sampler_kind = self.samplerKindOf(call.args[0]) orelse
            return self.fail(call.line, call.column, "texelFetch requires a sampler uniform", .{});
        const object = switch (call.args[0].*) {
            .identifier => |ident| ident.name,
            else => return self.fail(call.line, call.column, "texelFetch requires a sampler identifier", .{}),
        };
        try self.code.print("{s}.Load(", .{object});
        if (sampler_kind.isBuffer()) {
            try self.emitExprPrec(call.args[1], 1);
        } else {
            const dims = sampler_kind.coordDims();
            const width = if (sampler_kind.isArray()) dims + 1 else dims;
            const vector_len = width + 1;
            try self.code.print("int{d}(", .{vector_len});
            try self.emitExprPrec(call.args[1], 1);
            try self.code.write(", ");
            try self.emitExprPrec(call.args[2], 1);
            try self.code.write(")");
        }
        try self.code.write(")");
    }

    fn samplerKindOf(self: *Emitter, expression: *ast.Expr) ?types.SamplerKind {
        return switch (self.typeOf(expression)) {
            .sampler => |kind| kind,
            else => null,
        };
    }

    fn builtinText(self: *Emitter, name: []const u8, line: u32, column: u32) Error!?[]const u8 {
        if (self.stage == .vertex) {
            if (std.mem.eql(u8, name, "gl_Position")) return "output.gl_position";
            if (std.mem.eql(u8, name, "gl_VertexID")) return "input.gl_vertex_id";
            if (std.mem.eql(u8, name, "gl_InstanceID")) return "input.gl_instance_id";
        } else {
            if (std.mem.eql(u8, name, "gl_FragCoord")) return "input.gl_frag_coord";
            if (std.mem.eql(u8, name, "gl_FrontFacing")) return "input.gl_front_facing";
            if (std.mem.eql(u8, name, "gl_FragColor")) return "output.gl_frag_color";
            if (std.mem.eql(u8, name, "gl_FragDepth")) return "output.gl_frag_depth";
        }
        if (isStageBuiltin(name)) {
            return self.fail(line, column, "built-in '{s}' is not available in this stage", .{name});
        }
        return null;
    }

    fn typeOf(self: *Emitter, expression: *ast.Expr) types.Type {
        const unknown: types.Type = .unknown;
        switch (expression.*) {
            .int_literal => return .{ .scalar = .int },
            .uint_literal => return .{ .scalar = .uint },
            .float_literal => return .{ .scalar = .float },
            .bool_literal => return .{ .scalar = .bool },
            .identifier => |ident| {
                if (self.findLocal(ident.name)) |local| return local.typ;
                if (self.findGlobal(ident.name)) |global| return global.typ;
                if (builtinType(ident.name)) |typ| return typ;
                return unknown;
            },
            .unary => |unary| return self.typeOf(unary.operand),
            .postfix => |postfix| return self.typeOf(postfix.operand),
            .binary => |binary| return self.binaryType(binary),
            .assign => |assign| return self.typeOf(assign.target),
            .ternary => |ternary| return self.typeOf(ternary.then_expr),
            .call => |call| return self.callType(call),
            .member => |member| return self.memberType(member),
            .index => |index| return self.indexType(index),
            .comma => |comma| return self.typeOf(comma.right),
        }
    }

    fn binaryType(self: *Emitter, binary: ast.Binary) types.Type {
        const left = self.typeOf(binary.left);
        const right = self.typeOf(binary.right);
        switch (binary.op) {
            .logical_and,
            .logical_or,
            .logical_xor,
            .less,
            .greater,
            .less_equal,
            .greater_equal,
            .equal,
            .not_equal,
            => {
                const count = componentCount(left);
                if (count > 1) return .{ .vector = .{ .scalar = .bool, .len = count } };
                return .{ .scalar = .bool };
            },
            .multiply => {
                if (left.isMatrix() and right.isVector()) {
                    return .{ .vector = .{ .scalar = .float, .len = left.matrix.rows } };
                }
                if (left.isVector() and right.isMatrix()) {
                    return .{ .vector = .{ .scalar = .float, .len = right.matrix.cols } };
                }
                if (left.isMatrix() and right.isMatrix()) {
                    return .{ .matrix = .{ .cols = right.matrix.cols, .rows = left.matrix.rows } };
                }
                return commonType(left, right);
            },
            else => return commonType(left, right),
        }
    }

    fn callType(self: *Emitter, call: ast.Call) types.Type {
        if (types.fromBuiltinName(call.callee)) |typ| return typ;
        if (self.findStruct(call.callee) != null) return .{ .named = call.callee };
        if (self.findFunction(call.callee)) |function| return self.resolveType(function.return_type);
        const intrinsic = builtins.classify(call.callee);
        switch (intrinsic) {
            .texture, .texture_lod, .texture_grad, .texel_fetch => {
                if (call.args.len > 0) {
                    if (self.samplerKindOf(call.args[0])) |kind| {
                        return .{ .vector = .{ .scalar = kind.baseScalar(), .len = 4 } };
                    }
                }
                return .{ .vector = .{ .scalar = .float, .len = 4 } };
            },
            .compare => {
                const count = if (call.args.len > 0) componentCount(self.typeOf(call.args[0])) else 1;
                return .{ .vector = .{ .scalar = .bool, .len = if (count > 1) count else 2 } };
            },
            .logical_not => return self.typeOf(call.args[0]),
            .matrix_comp_mult => return if (call.args.len > 0) self.typeOf(call.args[0]) else .unknown,
            .mix, .fract, .inversesqrt, .ddx, .ddy, .fma, .mod, .atan2 => {
                return if (call.args.len > 0) self.typeOf(call.args[0]) else .unknown;
            },
            else => {},
        }
        if (builtins.isPassthrough(call.callee)) {
            if (std.mem.eql(u8, call.callee, "dot") or std.mem.eql(u8, call.callee, "length") or
                std.mem.eql(u8, call.callee, "distance") or std.mem.eql(u8, call.callee, "determinant"))
            {
                return .{ .scalar = .float };
            }
            if (std.mem.eql(u8, call.callee, "cross")) return .{ .vector = .{ .scalar = .float, .len = 3 } };
            if (std.mem.eql(u8, call.callee, "any") or std.mem.eql(u8, call.callee, "all") or
                std.mem.eql(u8, call.callee, "isnan") or std.mem.eql(u8, call.callee, "isinf"))
            {
                return .{ .scalar = .bool };
            }
            if (std.mem.eql(u8, call.callee, "transpose") and call.args.len > 0) {
                const arg = self.typeOf(call.args[0]);
                if (arg.isMatrix()) return .{ .matrix = .{ .cols = arg.matrix.rows, .rows = arg.matrix.cols } };
            }
            if (call.args.len > 0) return self.typeOf(call.args[0]);
        }
        return .unknown;
    }

    fn memberType(self: *Emitter, member: ast.Member) types.Type {
        const base = self.typeOf(member.base);
        if ((base.isVector() or base.isScalar()) and swizzleLength(member.name) != null) {
            const len = swizzleLength(member.name).?;
            const scalar = base.scalarOf() orelse .float;
            if (len == 1) return .{ .scalar = scalar };
            return .{ .vector = .{ .scalar = scalar, .len = len } };
        }
        if (base == .named) {
            if (self.findStruct(base.named)) |s| {
                for (s.fields) |field| {
                    if (std.mem.eql(u8, field.name, member.name)) {
                        const typ = self.resolveType(field.typ);
                        if (field.array_len) |len| {
                            const pointer = self.allocType(typ) catch return .unknown;
                            return .{ .array = .{ .elem = pointer, .len = len } };
                        }
                        return typ;
                    }
                }
            }
        }
        return .unknown;
    }

    fn indexType(self: *Emitter, index: ast.Index) types.Type {
        const base = self.typeOf(index.base);
        switch (base) {
            .array => |array| return array.elem.*,
            .vector => |vector| return .{ .scalar = vector.scalar },
            else => return .unknown,
        }
    }

    fn allocType(self: *Emitter, typ: types.Type) Error!*const types.Type {
        const pointer = try self.allocator.create(types.Type);
        pointer.* = typ;
        return pointer;
    }

    fn resolveType(self: *Emitter, name: ast.TypeName) types.Type {
        if (types.fromBuiltinName(name.name)) |typ| return typ;
        if (self.findStruct(name.name) != null) return .{ .named = name.name };
        return .unknown;
    }

    fn paramType(self: *Emitter, param: ast.Parameter) types.Type {
        const typ = self.resolveType(param.typ);
        if (param.array_len) |expression| {
            if (self.constInt(expression)) |len| {
                const pointer = self.allocator.create(types.Type) catch return typ;
                pointer.* = typ;
                return .{ .array = .{ .elem = pointer, .len = len } };
            }
        }
        return typ;
    }

    fn findGlobal(self: *Emitter, name: []const u8) ?Global {
        for (self.globals.items) |global| {
            if (std.mem.eql(u8, global.name, name)) return global;
        }
        return null;
    }

    fn findLocal(self: *Emitter, name: []const u8) ?Local {
        var index = self.locals.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.locals.items[index].name, name)) return self.locals.items[index];
        }
        return null;
    }

    fn findStruct(self: *Emitter, name: []const u8) ?*ast.StructDecl {
        for (self.structs.items) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    fn findFunction(self: *Emitter, name: []const u8) ?*ast.Function {
        for (self.functions.items) |function| {
            if (std.mem.eql(u8, function.name, name)) return function;
        }
        return null;
    }

    fn arrayLen(self: *Emitter, expression: ?*ast.Expr, line: u32, column: u32) Error!?u32 {
        const expr = expression orelse return null;
        return self.constInt(expr) orelse
            self.fail(line, column, "array length must be a constant integer", .{});
    }

    fn constInt(self: *Emitter, expression: *ast.Expr) ?u32 {
        _ = self;
        const value = constIntValue(expression) orelse return null;
        if (value < 0 or value > std.math.maxInt(u32)) return null;
        return @intCast(value);
    }

    fn scanStmt(self: *Emitter, statement: *ast.Stmt) Error!void {
        switch (statement.*) {
            .block => |block| for (block.statements) |child| try self.scanStmt(child),
            .expr => |expression| try self.scanExpr(expression),
            .decl => |variables| for (variables) |variable| {
                if (variable.initializer) |initializer| try self.scanExpr(initializer);
                if (variable.array_len) |len| try self.scanExpr(len);
            },
            .if_stmt => |s| {
                try self.scanExpr(s.condition);
                try self.scanStmt(s.then_branch);
                if (s.else_branch) |branch| try self.scanStmt(branch);
            },
            .for_stmt => |s| {
                if (s.init) |init| try self.scanStmt(init);
                if (s.condition) |condition| try self.scanExpr(condition);
                if (s.increment) |increment| try self.scanExpr(increment);
                try self.scanStmt(s.body);
            },
            .while_stmt => |s| {
                try self.scanExpr(s.condition);
                try self.scanStmt(s.body);
            },
            .do_while => |s| {
                try self.scanStmt(s.body);
                try self.scanExpr(s.condition);
            },
            .switch_stmt => |s| {
                try self.scanExpr(s.expression);
                try self.scanStmt(s.body);
            },
            .return_stmt => |s| if (s.value) |value| try self.scanExpr(value),
            .case_label => |s| try self.scanExpr(s.value),
            .discard_stmt => self.use.discard = true,
            else => {},
        }
    }

    fn scanExpr(self: *Emitter, expression: *ast.Expr) Error!void {
        switch (expression.*) {
            .identifier => |ident| {
                if (std.mem.eql(u8, ident.name, "gl_Position")) self.use.gl_position = true;
                if (std.mem.eql(u8, ident.name, "gl_FragCoord")) self.use.gl_frag_coord = true;
                if (std.mem.eql(u8, ident.name, "gl_FrontFacing")) self.use.gl_front_facing = true;
                if (std.mem.eql(u8, ident.name, "gl_VertexID")) self.use.gl_vertex_id = true;
                if (std.mem.eql(u8, ident.name, "gl_InstanceID")) self.use.gl_instance_id = true;
                if (std.mem.eql(u8, ident.name, "gl_FragDepth")) self.use.gl_frag_depth = true;
                if (std.mem.eql(u8, ident.name, "gl_FragColor")) self.use.gl_frag_color = true;
            },
            .unary => |unary| try self.scanExpr(unary.operand),
            .postfix => |postfix| try self.scanExpr(postfix.operand),
            .binary => |binary| {
                try self.scanExpr(binary.left);
                try self.scanExpr(binary.right);
            },
            .assign => |assign| {
                try self.scanExpr(assign.target);
                try self.scanExpr(assign.value);
            },
            .ternary => |ternary| {
                try self.scanExpr(ternary.condition);
                try self.scanExpr(ternary.then_expr);
                try self.scanExpr(ternary.else_expr);
            },
            .call => |call| {
                if (std.mem.eql(u8, call.callee, "mod")) self.uses_mod = true;
                for (call.args) |arg| try self.scanExpr(arg);
            },
            .member => |member| try self.scanExpr(member.base),
            .index => |index| {
                try self.scanExpr(index.base);
                try self.scanExpr(index.index);
            },
            .comma => |comma| {
                try self.scanExpr(comma.left);
                try self.scanExpr(comma.right);
            },
            else => {},
        }
    }

    fn stmtUsesBuiltin(self: *Emitter, statement: *ast.Stmt) bool {
        return switch (statement.*) {
            .block => |block| blk: {
                for (block.statements) |child| if (self.stmtUsesBuiltin(child)) break :blk true;
                break :blk false;
            },
            .expr => |expression| exprUsesBuiltin(expression),
            .decl => |variables| blk: {
                for (variables) |variable| {
                    if (variable.initializer) |initializer| if (exprUsesBuiltin(initializer)) break :blk true;
                }
                break :blk false;
            },
            .if_stmt => |s| exprUsesBuiltin(s.condition) or self.stmtUsesBuiltin(s.then_branch) or
                (s.else_branch != null and self.stmtUsesBuiltin(s.else_branch.?)),
            .for_stmt => |s| blk: {
                if (s.init) |init| if (self.stmtUsesBuiltin(init)) break :blk true;
                if (s.condition) |condition| if (exprUsesBuiltin(condition)) break :blk true;
                if (s.increment) |increment| if (exprUsesBuiltin(increment)) break :blk true;
                break :blk self.stmtUsesBuiltin(s.body);
            },
            .while_stmt => |s| exprUsesBuiltin(s.condition) or self.stmtUsesBuiltin(s.body),
            .do_while => |s| self.stmtUsesBuiltin(s.body) or exprUsesBuiltin(s.condition),
            .switch_stmt => |s| exprUsesBuiltin(s.expression) or self.stmtUsesBuiltin(s.body),
            .return_stmt => |s| s.value != null and exprUsesBuiltin(s.value.?),
            .case_label => |s| exprUsesBuiltin(s.value),
            else => false,
        };
    }

    fn stmtUsesName(self: *Emitter, statement: *ast.Stmt, name: []const u8) bool {
        _ = self;
        return stmtReferencesName(statement, name);
    }

    fn fail(self: *Emitter, line: u32, column: u32, comptime fmt: []const u8, args: anytype) Error {
        try self.diagnostics.errFmt(line, column, fmt, args);
        return error.InvalidShader;
    }
};

fn stmtReferencesName(statement: *ast.Stmt, name: []const u8) bool {
    return switch (statement.*) {
        .block => |block| blk: {
            for (block.statements) |child| if (stmtReferencesName(child, name)) break :blk true;
            break :blk false;
        },
        .expr => |expression| exprReferencesName(expression, name),
        .decl => |variables| blk: {
            for (variables) |variable| {
                if (variable.initializer) |initializer| if (exprReferencesName(initializer, name)) break :blk true;
            }
            break :blk false;
        },
        .if_stmt => |s| exprReferencesName(s.condition, name) or stmtReferencesName(s.then_branch, name) or
            (s.else_branch != null and stmtReferencesName(s.else_branch.?, name)),
        .for_stmt => |s| blk: {
            if (s.init) |init| if (stmtReferencesName(init, name)) break :blk true;
            if (s.condition) |condition| if (exprReferencesName(condition, name)) break :blk true;
            if (s.increment) |increment| if (exprReferencesName(increment, name)) break :blk true;
            break :blk stmtReferencesName(s.body, name);
        },
        .while_stmt => |s| exprReferencesName(s.condition, name) or stmtReferencesName(s.body, name),
        .do_while => |s| stmtReferencesName(s.body, name) or exprReferencesName(s.condition, name),
        .switch_stmt => |s| exprReferencesName(s.expression, name) or stmtReferencesName(s.body, name),
        .return_stmt => |s| s.value != null and exprReferencesName(s.value.?, name),
        .case_label => |s| exprReferencesName(s.value, name),
        else => false,
    };
}

fn exprReferencesName(expression: *ast.Expr, name: []const u8) bool {
    return switch (expression.*) {
        .identifier => |ident| std.mem.eql(u8, ident.name, name),
        .unary => |unary| exprReferencesName(unary.operand, name),
        .postfix => |postfix| exprReferencesName(postfix.operand, name),
        .binary => |binary| exprReferencesName(binary.left, name) or exprReferencesName(binary.right, name),
        .assign => |assign| exprReferencesName(assign.target, name) or exprReferencesName(assign.value, name),
        .ternary => |ternary| exprReferencesName(ternary.condition, name) or
            exprReferencesName(ternary.then_expr, name) or exprReferencesName(ternary.else_expr, name),
        .call => |call| blk: {
            for (call.args) |arg| if (exprReferencesName(arg, name)) break :blk true;
            break :blk false;
        },
        .member => |member| exprReferencesName(member.base, name),
        .index => |index| exprReferencesName(index.base, name) or exprReferencesName(index.index, name),
        .comma => |comma| exprReferencesName(comma.left, name) or exprReferencesName(comma.right, name),
        else => false,
    };
}

fn exprUsesBuiltin(expression: *ast.Expr) bool {
    return switch (expression.*) {
        .identifier => |ident| isStageBuiltin(ident.name),
        .unary => |unary| exprUsesBuiltin(unary.operand),
        .postfix => |postfix| exprUsesBuiltin(postfix.operand),
        .binary => |binary| exprUsesBuiltin(binary.left) or exprUsesBuiltin(binary.right),
        .assign => |assign| exprUsesBuiltin(assign.target) or exprUsesBuiltin(assign.value),
        .ternary => |ternary| exprUsesBuiltin(ternary.condition) or
            exprUsesBuiltin(ternary.then_expr) or exprUsesBuiltin(ternary.else_expr),
        .call => |call| blk: {
            for (call.args) |arg| if (exprUsesBuiltin(arg)) break :blk true;
            break :blk false;
        },
        .member => |member| exprUsesBuiltin(member.base),
        .index => |index| exprUsesBuiltin(index.base) or exprUsesBuiltin(index.index),
        .comma => |comma| exprUsesBuiltin(comma.left) or exprUsesBuiltin(comma.right),
        else => false,
    };
}

fn isStageBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "gl_Position") or
        std.mem.eql(u8, name, "gl_FragCoord") or
        std.mem.eql(u8, name, "gl_FrontFacing") or
        std.mem.eql(u8, name, "gl_VertexID") or
        std.mem.eql(u8, name, "gl_InstanceID") or
        std.mem.eql(u8, name, "gl_FragDepth") or
        std.mem.eql(u8, name, "gl_FragColor");
}

fn builtinType(name: []const u8) ?types.Type {
    if (std.mem.eql(u8, name, "gl_Position") or std.mem.eql(u8, name, "gl_FragCoord") or
        std.mem.eql(u8, name, "gl_FragColor"))
    {
        return .{ .vector = .{ .scalar = .float, .len = 4 } };
    }
    if (std.mem.eql(u8, name, "gl_FrontFacing")) return .{ .scalar = .bool };
    if (std.mem.eql(u8, name, "gl_VertexID") or std.mem.eql(u8, name, "gl_InstanceID")) return .{ .scalar = .int };
    if (std.mem.eql(u8, name, "gl_FragDepth")) return .{ .scalar = .float };
    return null;
}

fn layoutValue(qualifiers: ast.Qualifiers, name: []const u8) ?i64 {
    for (qualifiers.layout) |layout| {
        if (std.mem.eql(u8, layout.name, name)) return layout.value;
    }
    return null;
}

fn samplerObjectType(kind: types.SamplerKind) []const u8 {
    if (kind.isBuffer()) return "Buffer";
    return switch (kind) {
        .sampler1D, .sampler1DArray, .isampler1D, .usampler1D => "Texture1D",
        .sampler3D, .isampler3D, .usampler3D => "Texture3D",
        .samplerCube, .samplerCubeArray, .isamplerCube, .usamplerCube => "TextureCube",
        else => "Texture2D",
    };
}

fn samplerElementType(kind: types.SamplerKind) []const u8 {
    return switch (kind.baseScalar()) {
        .int => "int4",
        .uint => "uint4",
        else => "float4",
    };
}

fn exprPrecedence(expression: *ast.Expr) u8 {
    return switch (expression.*) {
        .comma => 0,
        .assign => 1,
        .ternary => 2,
        .binary => |binary| binaryPrecedence(binary.op),
        .unary => 13,
        .postfix, .call, .member, .index => 14,
        else => 15,
    };
}

fn binaryPrecedence(op: ast.BinaryOp) u8 {
    return switch (op) {
        .logical_or => 3,
        .logical_and => 4,
        .bit_or => 5,
        .bit_xor => 6,
        .bit_and => 7,
        .equal, .not_equal => 8,
        .less, .greater, .less_equal, .greater_equal => 9,
        .shift_left, .shift_right => 10,
        .add, .subtract => 11,
        .multiply, .divide, .remainder => 12,
        .logical_xor => 8,
    };
}

fn binaryOperator(op: ast.BinaryOp) []const u8 {
    return switch (op) {
        .add => "+",
        .subtract => "-",
        .multiply => "*",
        .divide => "/",
        .remainder => "%",
        .less => "<",
        .greater => ">",
        .less_equal => "<=",
        .greater_equal => ">=",
        .equal => "==",
        .not_equal => "!=",
        .logical_and => "&&",
        .logical_or => "||",
        .logical_xor => "!=",
        .bit_and => "&",
        .bit_or => "|",
        .bit_xor => "^",
        .shift_left => "<<",
        .shift_right => ">>",
    };
}

fn assignOperator(op: ast.AssignOp) []const u8 {
    return switch (op) {
        .assign => "=",
        .add => "+=",
        .subtract => "-=",
        .multiply => "*=",
        .divide => "/=",
        .remainder => "%=",
        .bit_and => "&=",
        .bit_or => "|=",
        .bit_xor => "^=",
        .shift_left => "<<=",
        .shift_right => ">>=",
    };
}

fn componentCount(typ: types.Type) u8 {
    return typ.componentCount() orelse 1;
}

fn commonType(left: types.Type, right: types.Type) types.Type {
    if (left == .unknown) return right;
    if (right == .unknown) return left;
    if (left.isMatrix()) return left;
    if (right.isMatrix()) return right;
    if (left.isVector() and right.isVector()) {
        return .{ .vector = .{
            .scalar = types.commonScalar(left.vector.scalar, right.vector.scalar),
            .len = @max(left.vector.len, right.vector.len),
        } };
    }
    if (left.isVector()) {
        const scalar = if (right.isScalar()) types.commonScalar(left.vector.scalar, right.scalar) else left.vector.scalar;
        return .{ .vector = .{ .scalar = scalar, .len = left.vector.len } };
    }
    if (right.isVector()) {
        const scalar = if (left.isScalar()) types.commonScalar(left.scalar, right.vector.scalar) else right.vector.scalar;
        return .{ .vector = .{ .scalar = scalar, .len = right.vector.len } };
    }
    if (left.isScalar() and right.isScalar()) {
        return .{ .scalar = types.commonScalar(left.scalar, right.scalar) };
    }
    return left;
}

fn swizzleLength(name: []const u8) ?u8 {
    if (name.len == 0 or name.len > 4) return null;
    for (name) |c| {
        switch (c) {
            'x', 'r', 's', 'y', 'g', 't', 'z', 'b', 'p', 'w', 'a', 'q' => {},
            else => return null,
        }
    }
    return @intCast(name.len);
}

fn swizzlePrefix(len: u8) []const u8 {
    return switch (len) {
        1 => "x",
        2 => "xy",
        3 => "xyz",
        else => "xyzw",
    };
}

fn scalarLiteral(scalar: types.Scalar, one: bool) []const u8 {
    if (scalar == .bool) return if (one) "true" else "false";
    return if (one) "1" else "0";
}

fn isBoolValue(typ: types.Type) bool {
    return switch (typ) {
        .scalar => |scalar| scalar == .bool,
        .vector => |vector| vector.scalar == .bool,
        else => false,
    };
}

fn constIntValue(expression: *ast.Expr) ?i64 {
    return switch (expression.*) {
        .int_literal => |text| std.fmt.parseInt(i64, text, 0) catch null,
        .uint_literal => |text| std.fmt.parseInt(i64, text, 0) catch null,
        .unary => |unary| blk: {
            const value = constIntValue(unary.operand) orelse break :blk null;
            break :blk switch (unary.op) {
                .plus => value,
                .minus => -value,
                .bit_not => ~value,
                .logical_not => @intFromBool(value == 0),
            };
        },
        .binary => |binary| blk: {
            const left = constIntValue(binary.left) orelse break :blk null;
            const right = constIntValue(binary.right) orelse break :blk null;
            break :blk switch (binary.op) {
                .add => left +% right,
                .subtract => left -% right,
                .multiply => left *% right,
                .divide => if (right == 0) null else @divTrunc(left, right),
                .remainder => if (right == 0) null else @rem(left, right),
                .shift_left => if (right < 0 or right >= 64) null else left << @intCast(right),
                .shift_right => if (right < 0 or right >= 64) null else left >> @intCast(right),
                .bit_and => left & right,
                .bit_or => left | right,
                .bit_xor => left ^ right,
                else => null,
            };
        },
        else => null,
    };
}

pub fn inferStage(unit: *ast.TranslationUnit, diagnostics: *diag.Diagnostics) Error!ast.Stage {
    var use = BuiltinUse{};
    var has_sampler = false;
    for (unit.decls) |decl| {
        switch (decl.*) {
            .function => |function| {
                if (function.body) |body| {
                    var scanner = BuiltinScanner{ .use = &use };
                    try scanner.scanStmt(body);
                }
            },
            .var_decl => |variable| {
                if (variable.qualifiers.storage) |storage| {
                    if (storage == .uniform) {
                        if (types.fromBuiltinName(variable.typ.name)) |typ| {
                            if (typ.isSampler()) has_sampler = true;
                        }
                    }
                }
            },
            else => {},
        }
    }
    const vertex = use.gl_position or use.gl_vertex_id or use.gl_instance_id;
    const fragment = use.gl_frag_coord or use.gl_front_facing or use.gl_frag_color or
        use.gl_frag_depth or use.discard or has_sampler;
    if (vertex and fragment) {
        try diagnostics.err(1, 1, "shader uses both vertex and fragment stage built-ins");
        return error.InvalidShader;
    }
    if (vertex) return .vertex;
    if (fragment) return .fragment;
    try diagnostics.warn(1, 1, "could not infer shader stage; assuming fragment");
    return .fragment;
}

const BuiltinScanner = struct {
    use: *BuiltinUse,

    fn scanStmt(self: *BuiltinScanner, statement: *ast.Stmt) Error!void {
        switch (statement.*) {
            .block => |block| for (block.statements) |child| try self.scanStmt(child),
            .expr => |expression| try self.scanExpr(expression),
            .decl => |variables| for (variables) |variable| {
                if (variable.initializer) |initializer| try self.scanExpr(initializer);
            },
            .if_stmt => |s| {
                try self.scanExpr(s.condition);
                try self.scanStmt(s.then_branch);
                if (s.else_branch) |branch| try self.scanStmt(branch);
            },
            .for_stmt => |s| {
                if (s.init) |init| try self.scanStmt(init);
                if (s.condition) |condition| try self.scanExpr(condition);
                if (s.increment) |increment| try self.scanExpr(increment);
                try self.scanStmt(s.body);
            },
            .while_stmt => |s| {
                try self.scanExpr(s.condition);
                try self.scanStmt(s.body);
            },
            .do_while => |s| {
                try self.scanStmt(s.body);
                try self.scanExpr(s.condition);
            },
            .switch_stmt => |s| {
                try self.scanExpr(s.expression);
                try self.scanStmt(s.body);
            },
            .return_stmt => |s| if (s.value) |value| try self.scanExpr(value),
            .case_label => |s| try self.scanExpr(s.value),
            .discard_stmt => self.use.discard = true,
            else => {},
        }
    }

    fn scanExpr(self: *BuiltinScanner, expression: *ast.Expr) Error!void {
        switch (expression.*) {
            .identifier => |ident| {
                if (std.mem.eql(u8, ident.name, "gl_Position")) self.use.gl_position = true;
                if (std.mem.eql(u8, ident.name, "gl_FragCoord")) self.use.gl_frag_coord = true;
                if (std.mem.eql(u8, ident.name, "gl_FrontFacing")) self.use.gl_front_facing = true;
                if (std.mem.eql(u8, ident.name, "gl_VertexID")) self.use.gl_vertex_id = true;
                if (std.mem.eql(u8, ident.name, "gl_InstanceID")) self.use.gl_instance_id = true;
                if (std.mem.eql(u8, ident.name, "gl_FragDepth")) self.use.gl_frag_depth = true;
                if (std.mem.eql(u8, ident.name, "gl_FragColor")) self.use.gl_frag_color = true;
            },
            .unary => |unary| try self.scanExpr(unary.operand),
            .postfix => |postfix| try self.scanExpr(postfix.operand),
            .binary => |binary| {
                try self.scanExpr(binary.left);
                try self.scanExpr(binary.right);
            },
            .assign => |assign| {
                try self.scanExpr(assign.target);
                try self.scanExpr(assign.value);
            },
            .ternary => |ternary| {
                try self.scanExpr(ternary.condition);
                try self.scanExpr(ternary.then_expr);
                try self.scanExpr(ternary.else_expr);
            },
            .call => |call| for (call.args) |arg| try self.scanExpr(arg),
            .member => |member| try self.scanExpr(member.base),
            .index => |index| {
                try self.scanExpr(index.base);
                try self.scanExpr(index.index);
            },
            .comma => |comma| {
                try self.scanExpr(comma.left);
                try self.scanExpr(comma.right);
            },
            else => {},
        }
    }
};

test "emit simple vertex shader" {
    const preprocess = @import("../glsl/preprocess.zig");
    const tokenizer = @import("../glsl/token.zig");
    const parser = @import("../glsl/parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess.preprocess(allocator,
        \\#version 330 core
        \\layout(location = 0) in vec3 a_position;
        \\uniform mat4 u_mvp;
        \\void main() {
        \\    gl_Position = u_mvp * vec4(a_position, 1.0);
        \\}
    , &diagnostics);
    const tokens = try tokenizer.tokenize(allocator, result.source, &diagnostics);
    var parser_instance = parser.Parser.init(allocator, tokens, &diagnostics);
    const unit = try parser_instance.parse();
    const output = try emit(allocator, unit, .vertex, &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, output, "cbuffer Globals : register(b0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "struct VSInput") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "POSITION") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mul(u_mvp") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "output.gl_position") != null);
}

test "emit simple fragment shader" {
    const preprocess = @import("../glsl/preprocess.zig");
    const tokenizer = @import("../glsl/token.zig");
    const parser = @import("../glsl/parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const result = try preprocess.preprocess(allocator,
        \\#version 330 core
        \\in vec2 v_uv;
        \\uniform sampler2D u_tex;
        \\out vec4 frag_color;
        \\void main() {
        \\    frag_color = texture(u_tex, v_uv);
        \\}
    , &diagnostics);
    const tokens = try tokenizer.tokenize(allocator, result.source, &diagnostics);
    var parser_instance = parser.Parser.init(allocator, tokens, &diagnostics);
    const unit = try parser_instance.parse();
    const output = try emit(allocator, unit, .fragment, &diagnostics);
    try std.testing.expect(std.mem.indexOf(u8, output, "Texture2D<float4> u_tex : register(t0);") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "SamplerState u_tex_sampler") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "u_tex.Sample(u_tex_sampler, input.v_uv)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "frag_color : SV_Target0") != null);
}

test "emit keeps struct member names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const output = try emitSource(allocator, &diagnostics,
        \\#version 330 core
        \\struct Material { vec3 albedo; float roughness; };
        \\uniform Material u_material;
        \\out vec4 c;
        \\void main() { c = vec4(u_material.albedo, 1.0); }
    , .fragment);
    try std.testing.expect(std.mem.indexOf(u8, output, "u_material.albedo") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "wlzedo") == null);
}

test "emit uses SampleLevel for vertex textures" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const output = try emitSource(allocator, &diagnostics,
        \\#version 330 core
        \\in vec2 v_uv;
        \\uniform sampler2D u_tex;
        \\void main() {
        \\    vec4 t = texture(u_tex, v_uv);
        \\    gl_Position = t;
        \\}
    , .vertex);
    try std.testing.expect(std.mem.indexOf(u8, output, "u_tex.SampleLevel(u_tex_sampler, input.v_uv, 0.0)") != null);
}

test "emit widens short vector constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const output = try emitSource(allocator, &diagnostics,
        \\#version 330 core
        \\out vec4 c;
        \\void main() {
        \\    vec3 v = vec3(1.0);
        \\    c = vec4(v);
        \\    c.xyz = vec3(vec2(1.0, 2.0));
        \\}
    , .fragment);
    try std.testing.expect(std.mem.indexOf(u8, output, "float4(v, 1)") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "float3(float2(1.0, 2.0), 0)") != null);
}

test "emit rewrites matrix compound multiplication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var diagnostics = diag.Diagnostics.init(allocator);
    const output = try emitSource(allocator, &diagnostics,
        \\#version 330 core
        \\uniform mat4 u_m;
        \\void main() {
        \\    mat4 m = u_m;
        \\    m *= mat4(2.0);
        \\    gl_Position = m * vec4(1.0);
        \\}
    , .vertex);
    try std.testing.expect(std.mem.indexOf(u8, output, "m = mul(m, float4x4(2.0, 0, 0, 0") != null);
}

pub fn emit(allocator: std.mem.Allocator, unit: *ast.TranslationUnit, stage: ast.Stage, diagnostics: *diag.Diagnostics) Error![]const u8 {
    var emitter = Emitter{
        .allocator = allocator,
        .diagnostics = diagnostics,
        .stage = stage,
        .unit = unit,
        .code = code_writer.Code.init(allocator),
    };
    return emitter.run();
}

fn emitSource(allocator: std.mem.Allocator, diagnostics: *diag.Diagnostics, source: []const u8, stage: ast.Stage) Error![]const u8 {
    const preprocess = @import("../glsl/preprocess.zig");
    const tokenizer = @import("../glsl/token.zig");
    const parser = @import("../glsl/parser.zig");
    const result = try preprocess.preprocess(allocator, source, diagnostics);
    const tokens = try tokenizer.tokenize(allocator, result.source, diagnostics);
    var parser_instance = parser.Parser.init(allocator, tokens, diagnostics);
    const unit = try parser_instance.parse();
    return emit(allocator, unit, stage, diagnostics);
}
