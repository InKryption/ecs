const std = @import("std");
const mem = std.mem;
const math = std.math;
const meta = std.meta;
const enums = std.enums;
const debug = std.debug;
const testing = std.testing;
const builtin = std.builtin;

const assert = debug.assert;
const Allocator = mem.Allocator;
const TypeInfo = builtin.TypeInfo;

pub fn BasicRegistry(comptime S: type) type {
    if (@typeInfo(S) != .Struct) @compileError("Expected a Struct type.");
    return struct {
        const Self = @This();
        _graveyard: usize = 0,
        _store: meta_info.DataStore.Slice = .{
            .ptrs = undefined,
            .len = 0,
            .capacity = 0,
        },

        pub const Struct = S;
        pub const ComponentName = meta_info.ComponentName;
        pub const Entity = enum(usize) {
            const Tag = meta.Tag(@This());
            _,
        };

        pub fn initCapacity(allocator: Allocator, capacity: usize) !Self {
            var result = Self{};
            errdefer result.deinit(allocator);
            try result.ensureTotalCapacity(allocator, capacity);
            return result;
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self._store.deinit(allocator);
            self.* = .{};
        }

        pub fn create(self: *Self, allocator: *Allocator) Allocator.Error!Entity {
            var one_entity: [1]Entity = undefined;
            self.createMany(allocator, &one_entity);
            return one_entity[0];
        }

        pub fn destroy(self: *Self, entity: Entity) void {
            self.destroyMany(&[_]Entity{ entity });
        }

        pub fn createAssumeCapacity(self: *Self) Entity {
            var one_entity: [1]Entity = undefined;
            self.createManyAssumeCapacity(&one_entity);
            return one_entity[0];
        }

        pub fn createMany(self: *Self, allocator: Allocator, entities: []Entity) Allocator.Error!void {
            try self.ensureUnusedCapacity(allocator, entities.len);
            self.createManyAssumeCapacity(entities);
        }

        pub fn createManyAssumeCapacity(self: *Self, entities: []Entity) void {
            const resurrected_entity_count = math.clamp(self._graveyard, 0, entities.len);

            assert((entities.len - resurrected_entity_count) <= (self._store.capacity - self._store.len));
            var store_as_multi_array_list = self._store.toMultiArrayList();
            defer self._store = store_as_multi_array_list.toOwnedSlice();

            if (resurrected_entity_count != 0) {
                var i: usize = 0;
                while (i < resurrected_entity_count) : (i += 1) {
                    self._graveyard -= 1;
                    entities[i] = @intToEnum(Entity, self._graveyard);
                }
            }

            const remaining_uninitialized = entities[resurrected_entity_count..];
            for (remaining_uninitialized) |*ent| {
                const entity_int_value = self._store.len;
                ent.* = @intToEnum(Entity, entity_int_value);
                store_as_multi_array_list.appendAssumeCapacity(meta_info.makeDefaultEntityDataStruct(entity_int_value));
            }
        }

        pub fn destroyMany(self: *Self, entities: []const Entity) void {
            for (entities) |ent| {
                assert(self.entityIsAlive(ent));
                self.swapEntityPositions(ent, @intToEnum(Entity, self._graveyard));
                self._graveyard += 1;
            }
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, capacity: usize) Allocator.Error!void {
            var store_as_multi_array_list = self._store.toMultiArrayList();
            defer self._store = store_as_multi_array_list.toOwnedSlice();
            try store_as_multi_array_list.ensureTotalCapacity(allocator, capacity);
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, capacity: usize) Allocator.Error!void {
            var store_as_multi_array_list = self._store.toMultiArrayList();
            defer self._store = store_as_multi_array_list.toOwnedSlice();
            try store_as_multi_array_list.ensureUnusedCapacity(allocator, capacity - math.clamp(self._graveyard, 0, capacity));
        }

        pub fn get(self: Self, entity: Entity, comptime component: ComponentName) ?ComponentType(component) {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            if (!self.has(entity, component)) return null;
            return self.getSliceOfComponentValues(component)[index];
        }

        pub fn getPtr(self: *Self, entity: Entity, comptime component: ComponentName) ?*ComponentType(component) {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            if (!self.has(entity, component)) return null;
            return &self.getSliceOfComponentValues(component)[index];
        }

        pub fn has(self: Self, entity: Entity, comptime component: ComponentName) bool {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            return self.getSliceOfComponentFlags(component)[index];
        }

        pub const ComponentFlags = meta_info.ComponentFlags;

        pub fn hasAny(self: Self, entity: Entity, comptime components: ComponentFlags) bool {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            inline for (comptime enums.values(ComponentName)) |name| {
                if (@field(components, @tagName(name))) {
                    const flags = self.getSliceOfComponentFlags(name);
                    if (flags[index]) return true;
                }
            }
            return false;
        }

        pub fn hasAll(self: Self, entity: Entity, comptime components: ComponentFlags) bool {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            inline for (comptime enums.values(ComponentName)) |name| {
                const flags = self.getSliceOfComponentFlags(name);
                if (@field(components, @tagName(name))) {
                    if (!flags[index]) return false;
                }
            }
            return true;
        }

        pub fn assign(self: *Self, entity: Entity, comptime component: ComponentName) *ComponentType(component) {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            const flags = self.getSliceOfComponentFlags(component);

            assert(!flags[index]);
            flags[index] = true;
            const ptr = self.getPtr(entity, component).?;
            ptr.* = undefined;
            return ptr;
        }

        pub fn remove(self: *Self, entity: Entity, comptime component: ComponentName) ComponentType(component) {
            assert(self.entityIsAlive(entity));
            const index = self.getEntityComponentsIndex(entity);
            const flags = self.getSliceOfComponentFlags(component);
            
            assert(flags[index]);
            const val = self.get().?;
            flags[index] = false;

            return val;
        }

        pub const WriteEntityOptions = struct {
            prefix: ?Prefix = .period,
            null_components: bool = false,
            /// if non-null, newlines are inserted between each field,
            /// and before and after the first and last fields, respectively.
            newline_indentation: ?NewlineIndentation = null,
            /// Used for indentation
            eol: Eol = .lf,
            pub const Prefix = enum { entity_id, period };
            pub const NewlineIndentation = union(enum) { tabs: u4, spaces: u4 };
            pub const Eol = enum { lf, crlf };
        };
        pub fn writeEntity(
            self: Self,
            entity: Entity,
            writer: anytype,
            comptime options: WriteEntityOptions,
        ) @TypeOf(writer).Error!void {
            const component_names = comptime enums.values(ComponentName);
            const eol: []const u8 = comptime switch (options.eol) { .lf => "\n", .crlf => "\n\r" };
            const indentation: []const u8 = if (options.newline_indentation) |nli| switch (nli) {
                .tabs => |tabs|  &([_]u8{ '\t' } ** (tabs + 1)),
                .spaces => |spaces| &([_]u8{ ' ' } ** (spaces + 1)),
            } else "";
            const after_field: []const u8 = if (indentation.len != 0) eol else " ";

            if (indentation.len != 0) try writer.writeAll(indentation[1..]);

            if (comptime options.prefix) |prefix| switch (prefix) {
                .entity_id => try writer.print("{}", .{ entity }),
                .period => try writer.writeByte('.'),
            };

            try writer.writeByte('{');

            if (enums.values(ComponentName).len == 0 or is_empty: {
                comptime var component_flags: ComponentFlags = .{};
                inline for (component_names) |name| @field(component_flags, @tagName(name)) = true;
                break :is_empty !self.hasAny(entity, component_flags);
            }) return try writer.writeByte('}');

            if (options.newline_indentation != null) try writer.writeAll(eol);

            inline for (component_names) |name| {
                if (self.get(entity, name)) |val| {
                    try writer.print(indentation ++ ".{s} = {any}," ++ after_field, .{ @tagName(name), val });
                } else if (options.null_components) {
                    try writer.print(indentation ++ ".{s} = null," ++ after_field, .{ @tagName(name) });
                }
            }

            try writer.writeAll(indentation[1..] ++ "}");
        }

        pub const IterationType = enum { require_one, require_all };
        pub fn iterateLinearConst(
            self: *const Self,
            comptime E: ?type,
            comptime iteration_type: IterationType,
            comptime components: ComponentFlags,
            context: anytype,
            comptime function: fn (*const Self, Entity, @TypeOf(context)) (if (E) |Err| (Err!bool) else bool),
        ) (if (E) |Err| (Err!void) else void) {
            var entity = @intToEnum(Entity, self._graveyard);
            const sentinel_entity = @intToEnum(Entity, self._store.len);
            outer: while (entity != sentinel_entity) : (entity = @intToEnum(Entity, @enumToInt(entity) + 1)) {
                switch (iteration_type) {
                    .require_one => if (!self.hasAny(entity, components)) continue :outer,
                    .require_all => if (!self.hasAll(entity, components)) continue :outer,
                }

                const should_continue: bool = if (E != null) try function(self, entity, context) else function(self, entity, context);
                if (!should_continue) return;
            }
        }

        /// Swaps the indexes, and subsequently the values
        /// in each component row referred to by each index,
        /// of the given entities. This has no outwardly visible effect,
        /// except that it invalidates any pointers to the components of
        /// the given entities.
        /// Self doesn't need to be mutable here,
        /// but it's better to mark it as such, to indicate that
        /// mutation does indeed occur.
        fn swapEntityPositions(self: *Self, a: Entity, b: Entity) void {
            assert(self.entityIsValid(a));
            assert(self.entityIsValid(b));

            const indexes = self.getSliceOfIndices();
            mem.swap(usize, &indexes[@enumToInt(a)], &indexes[@enumToInt(b)]);

            const index_a = indexes[@enumToInt(a)];
            const index_b = indexes[@enumToInt(b)];
            inline for (comptime enums.values(ComponentName)) |name| {
                const flags = self.getSliceOfComponentFlags(name);
                mem.swap(bool, &flags[index_a], &flags[index_b]);

                const values = self.getSliceOfComponentValues(name);
                mem.swap(ComponentType(name), &values[index_a], &values[index_b]);
            }
        }

        inline fn getEntityComponentsIndex(self: Self, entity: Entity) usize {
            assert(self.entityIsValid(entity));
            return self.getSliceOfIndices()[@enumToInt(entity)];
        }

        inline fn entityIsAlive(self: Self, entity: Entity) bool {
            return self.entityIsValid(entity) and @enumToInt(entity) >= self._graveyard;
        }

        inline fn entityIsValid(self: Self, entity: Entity) bool {
            return @enumToInt(entity) < self._store.len;
        }

        fn getSliceOfComponentValues(self: Self, comptime component: ComponentName) []ComponentType(component) {
            const field_name = comptime meta_info.componentNameToFieldName(.value, component);
            return self._store.items(field_name);
        }

        fn getSliceOfComponentFlags(self: Self, comptime component: ComponentName) []bool {
            const field_name = comptime meta_info.componentNameToFieldName(.flag, component);
            return self._store.items(field_name);
        }

        fn getSliceOfIndices(self: Self) []usize {
            return self._store.items(.index);
        }

        const ComponentType = meta_info.ComponentType;
        const meta_info = BasicRegistryMetaUtil(S);
    };
}

fn BasicRegistryMetaUtil(comptime S: type) type {
    return struct {
        const DataStore = std.MultiArrayList(EntityDataStruct);

        /// A struct generated based off of the given input struct,
        /// and which is meant to be used as an argument to `std.MultiArrayList`.
        /// It contains two fields per field of the input struct, each
        /// pair of which possess the name of the respective field,
        /// prefixed "value_" and "flag_" respectively;
        /// after that, it contains a field called `index`,
        /// which is to be used as the index to get the row
        /// of components belonging to the Entity used to
        /// access the index in the `std.MultiArrayList`.
        const EntityDataStruct: type = EntityDataStruct: {
            var fields: [(meta.fields(S).len * 2) + 1]TypeInfo.StructField = undefined;
            for (meta.fields(S)) |field_info, i| {
                fields[i] = TypeInfo.StructField{
                    .name = (value_field_prefix ++ field_info.name),
                    .field_type = field_info.field_type,
                    .default_value = @as(?field_info.field_type, null),
                    .is_comptime = false,
                    .alignment = field_info.alignment,
                };
                fields[i + meta.fields(S).len] = TypeInfo.StructField{
                    .name = flag_field_prefix ++ field_info.name,
                    .field_type = bool,
                    .default_value = @as(?bool, null),
                    .is_comptime = false,
                    .alignment = @alignOf(bool),
                };
            }
            fields[fields.len - 1] = TypeInfo.StructField{
                .name = "index",
                .field_type = usize,
                .default_value = @as(?usize, null),
                .is_comptime = false,
                .alignment = @alignOf(usize),
            };
            break :EntityDataStruct @Type(@unionInit(TypeInfo, "Struct", TypeInfo.Struct{
                .layout = TypeInfo.ContainerLayout.Auto,
                .fields = @as([]const TypeInfo.StructField, &fields),
                .decls = &[_]TypeInfo.Declaration{},
                .is_tuple = false,
            }));
        };

        /// Returns an instance of `EntityDataStruct` with its index field
        /// set to the specified value, all flag fields set to false,
        /// and all value fields set to undefined.
        fn makeDefaultEntityDataStruct(index: usize) EntityDataStruct {
            var result: EntityDataStruct = undefined;
            result.index = index;
            inline for (comptime enums.values(ComponentName)) |name| {
                const field_name = comptime componentNameToFieldName(.flag, name);
                @field(result, @tagName(field_name)) = false;
            }
            return result;
        }

        const GeneratedFieldType = enum {
            value,
            flag,
            fn prefix(self: GeneratedFieldType) [:0]const u8 {
                return switch (self) {
                    .value => "value_",
                    .flag => "flag_",
                };
            }
        };

        const value_field_prefix = GeneratedFieldType.prefix(.value);
        const flag_field_prefix = GeneratedFieldType.prefix(.flag);

        const ComponentName = meta.FieldEnum(S);
        const FieldName = meta.FieldEnum(EntityDataStruct);

        const ComponentFlags = enums.EnumFieldStruct(ComponentName, bool, false);

        fn ComponentType(comptime name: ComponentName) type {
            return meta.fieldInfo(S, name).field_type;
        }

        inline fn componentNameToFieldName(
            comptime generated_field_type: GeneratedFieldType,
            comptime component_name: ComponentName,
        ) FieldName {
            const name_str = generated_field_type.prefix() ++ @tagName(component_name);
            return @field(FieldName, name_str);
        }

        
    };
}

test "BasicRegistry" {
    const Reg = BasicRegistry(struct {
        position: Position,
        velocity: Velocity,

        const Position = struct { x: f32, y: f32 };
        const Velocity = struct { x: f32, y: f32 };
    });

    var reg = try Reg.initCapacity(testing.allocator, 8);
    defer reg.deinit(testing.allocator);

    const ent0 = reg.createAssumeCapacity();
    const ent1 = reg.createAssumeCapacity();

    try testing.expect(!reg.has(ent0, .position));
    try testing.expect(!reg.has(ent0, .velocity));

    try testing.expect(!reg.has(ent1, .position));
    try testing.expect(!reg.has(ent1, .velocity));

    reg.assign(ent0, .position).* = Reg.Struct.Position{ .x = 0.2, .y = 0.3 };
    reg.assign(ent1, .velocity).* = Reg.Struct.Velocity{ .x = 122.0, .y = 10.4 };

    try testing.expect(reg.has(ent0, .position));
    try testing.expectEqual(reg.get(ent0, .position).?.x, 0.2);
    try testing.expectEqual(reg.get(ent0, .position).?.y, 0.3);

    try testing.expect(reg.has(ent1, .velocity));
    try testing.expectEqual(reg.get(ent1, .velocity).?.x, 122.0);
    try testing.expectEqual(reg.get(ent1, .velocity).?.y, 10.4);

    try std.io.getStdOut().writer().writeByte('\n');
    try reg.iterateLinearConst(
        std.fs.File.Writer.Error,
        .require_one,
        .{ .position = true, .velocity = true },
        std.io.getStdOut().writer(),
        struct { fn iterateFn(r: *const Reg, e: Reg.Entity, stdout: std.fs.File.Writer) std.fs.File.Writer.Error!bool {
            try r.writeEntity(e, stdout, .{ .null_components = false, .prefix = .entity_id, .newline_indentation = .{ .tabs = 0 } });
            try stdout.writeByte('\n');
            return true;
        } }.iterateFn
    );
}
