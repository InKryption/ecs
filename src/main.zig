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

        /// Swaps the indexes, and subsequently the values in each component row,
        /// of the given entities. This has no outwardly visible effect,
        /// except that it invalidates any pointers to the components of
        /// the given entities.
        /// Self doesn't need to be mutable here,
        /// but it's better to mark it as such, to indicate that
        /// mutation does indeed occur.
        fn swapEntityPositions(self: *Self, a: Entity, b: Entity) void {
            assert(self.entityIsValid(a));
            assert(self.entityIsValid(b));

            const indexes = self.getSliceOfIndexes();
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

        fn getEntityComponentsIndex(self: Self, entity: Entity) usize {
            return self.getSliceOfIndexes()[@enumToInt(entity)];
        }

        fn getSliceOfComponentValues(self: Self, comptime component: ComponentName) []ComponentType(component) {
            const field_name = comptime meta_info.componentNameToFieldName(.value, component);
            return self._store.items(field_name);
        }

        fn getSliceOfComponentFlags(self: Self, comptime component: ComponentName) []bool {
            const field_name = comptime meta_info.componentNameToFieldName(.flag, component);
            return self._store.items(field_name);
        }

        fn getSliceOfIndexes(self: Self) []usize {
            return self._store.items(.index);
        }

        fn entityIsAlive(self: Self, entity: Entity) bool {
            return self.entityIsValid(entity) and @enumToInt(entity) >= self._graveyard;
        }

        fn entityIsValid(self: Self, entity: Entity) bool {
            return @enumToInt(entity) < self._store.len;
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
            // fields = ([_]TypeInfo.StructField{
            //     .{
            //         .name = "",
            //         .field_type = @TypeOf(null),
            //         .default_value = @as(?@TypeOf(null), null),
            //         .is_comptime = true,
            //         .alignment = 0,
            //     },
            // } ** fields.len);
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

    reg.assign(ent0, .position).* = .{ .x = 0.2, .y = 0.3 };
    reg.assign(ent1, .velocity).* = .{ .x = 122.0, .y = 10.4 };

    try testing.expect(reg.has(ent0, .position));
    try testing.expectEqual(reg.get(ent0, .position).?.x, 0.2);
    try testing.expectEqual(reg.get(ent0, .position).?.y, 0.3);

    try testing.expect(reg.has(ent1, .velocity));
    try testing.expectEqual(reg.get(ent1, .velocity).?.x, 122.0);
    try testing.expectEqual(reg.get(ent1, .velocity).?.y, 10.4);
}
