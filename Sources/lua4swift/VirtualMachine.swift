import Foundation
import CLua

internal let RegistryIndex = Int(-LUAI_MAXSTACK - 1000)
private let GlobalsTable = Int(LUA_RIDX_GLOBALS)

private struct Future<T> {
    private let af: () async throws -> T

    init(_ af: @escaping () async throws -> T) {
        self.af = af
    }
}

public struct Lua {
    public class VirtualMachine {
        public let state: State
        public internal(set) var env: Table?

        public init(openLibs: Bool = true) {
            let state = State(openLibs: openLibs)
            let env = {
                let env = state.createTable(0, keyCapacity: 0)
                let meta = state.createTable(0, keyCapacity: 1)
                meta["__index"] = state.globals
                meta.becomeMetatableFor(env)
                return env
            }()

            self.state = state
            self.env = env
            self.state.env = env
        }

        deinit {
            self.env = nil
            luaC_fullgc(self.state.state, 0)
        }

        public func setFilePrefix(_ prefix: URL) throws {
            guard prefix.isFileURL, prefix.hasDirectoryPath else { return }
            let path = prefix.path + "/"
            path.withCString { pathPtr in
                luaL_set_loadfilex_prefix(pathPtr)
            }
        }

        public func preloadModules(_ modules: UnsafeMutablePointer<luaL_Reg>) {
            self.state.preloadModules(modules)
        }

        public var globals: Table {
            self.state.globals
        }

        public var registry: Table {
            self.state.registry
        }

        public func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> LuaValueRepresentable) -> Function {
            self.state.createFunction {
                try [fn($0)]
            }
        }

        public func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> Void) -> Function {
            self.state.createFunction {
                try fn($0)
                return []
            }
        }

        public func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> [LuaValueRepresentable]) -> Function {
            self.state.createFunction(fn)
        }

        public func createTable(_ sequenceCapacity: Int = 0, keyCapacity: Int = 0) -> Table {
            self.state.createTable(sequenceCapacity, keyCapacity: keyCapacity)
        }

        public func createUserdataMaybe<T: LuaCustomTypeInstance>(_ o: T?) -> Userdata? {
            if let u = o {
                return self.state.createUserdata(u)
            }
            return nil
        }

        public func createUserdata<T: LuaCustomTypeInstance>(_ o: T) -> Userdata {
            self.state.createUserdata(o)
        }

        public func eval(_ url: URL, args: [LuaValueRepresentable] = []) throws -> [LuaValueRepresentable] {
            let fn = try state.createFunction(url)
            return try eval(function: fn, args: args)
        }

        public func eval(_ str: String, args: [LuaValueRepresentable] = []) throws -> [LuaValueRepresentable] {
            let fn = try state.createFunction(str)
            return try eval(function: fn, args: args)
        }

        public func eval(function f: Function, args: [LuaValueRepresentable]) throws -> [LuaValueRepresentable] {
            try self.state.eval(function: f, args: args)
        }

        public func createCustomType<T>(_ setup: (CustomType<T>) -> Void) -> CustomType<T> {
            self.state.createCustomType(setup)
        }

        public func loadModule(name: String, url: URL) throws {
            try self.state.loadModule(name: name, url: url)
        }
    }

    public class State {
        internal let state = luaL_newstate()
        weak internal var env: Table?

        fileprivate init(openLibs: Bool) {
            if openLibs {
                luaL_openlibs(state)
            }
        }

        fileprivate func preloadModules(_ modules: UnsafeMutablePointer<luaL_Reg>) {
            lua_getglobal(state, "package")
            lua_getfield(state, -1, "preload");

            var module = modules.pointee

            while let name = module.name, let function = module.func {
                lua_pushcclosure(state, function, 0)
                lua_setfield(state, -2, name)

                module = modules.advanced(by: 1).pointee
            }

            lua_settop(state, -(2)-1)
        }

        // pops the value off the stack completely and returns it
        internal func popValue(_ pos: Int) -> LuaValueRepresentable? {
            moveToStackTop(pos)
            defer { pop() }
            switch lua_type(state, -1) {
            case LUA_TSTRING:
                var len: Int = 0
                let str = lua_tolstring(state, -1, &len)
                return String(cString: str!)
            case LUA_TNUMBER:
                if lua_isinteger(state, -1) == 1 {
                    return lua_tointegerx(state, -1, nil)
                } else {
                    return lua_tonumberx(state, -1, nil)
                }
            case LUA_TBOOLEAN:
                return lua_toboolean(state, -1) == 1 ? true : false
            case LUA_TFUNCTION:
                return Function(self)
            case LUA_TTABLE:
                return Table(self)
            case LUA_TUSERDATA:
                return Userdata(self)
            case LUA_TLIGHTUSERDATA:
                return LightUserdata(self)
            case LUA_TTHREAD:
                return Thread(self)
            case LUA_TNIL:
                return Nil.nil
            default:
                return nil
            }
        }

        internal var globals: Table {
            rawGet(tablePosition: RegistryIndex, index: GlobalsTable)
            return popValue(-1) as! Table
        }

        fileprivate var registry: Table {
            pushFromStack(RegistryIndex)
            return popValue(-1) as! Table
        }

        fileprivate func loadModule(name: String, url: URL) throws {
            let moduleStr = try String(contentsOf: url, encoding: .utf8)
            let f: @convention(block) (UnsafeMutablePointer<lua_State>?) -> Int32 = { [weak self] state in
                guard let self else { return 0 }
                let modName = lua_tolstring(state, 1, nil)
                let sModName = String(cString: modName!)
                var res: Int32 = 0

                if sModName == name {
                    let nameStr = name.utf8CString
                        nameStr.withUnsafeBufferPointer { namePtr in
                            res = luaL_loadbufferx(
                                state,
                                moduleStr,
                                moduleStr.count,
                                namePtr.baseAddress,
                                "t"
                            )
                    }
                } else {
                    // Unknown module
                    let unknownModStr = "unknown module '\(sModName)'"
                    unknownModStr.push(self)
                    lua_error(state)
                }

                if res != LUA_OK {
                    lua_error(state)
                }

                // Runs the Lua code and returns whatever it returns as the result of openf,
                // which will be used as the value of the module
                lua_callk(state, 0, 1, 0, nil)
                return 1
            }
            let block: AnyObject = unsafeBitCast(f, to: AnyObject.self)
            let imp = imp_implementationWithBlock(block)
            let fp = unsafeBitCast(imp, to: lua_CFunction.self)

            luaL_requiref(state, name, fp, 0)
        }

        fileprivate func createFunction(_ body: URL) throws -> Function {
            if luaL_loadfilex(state, body.path, nil) == LUA_OK {
                return popValue(-1) as! Function
            } else {
                throw Lua.Error.internal(popError())
            }
        }

        fileprivate func createFunction(_ body: String) throws -> Function {
            if luaL_loadstring(state, body.cString(using: .utf8)) == LUA_OK {
                return popValue(-1) as! Function
            } else {
                throw Lua.Error.internal(popError())
            }
        }

        public func createTable(_ sequenceCapacity: Int, keyCapacity: Int) -> Table {
            lua_createtable(state, Int32(sequenceCapacity), Int32(keyCapacity))
            return popValue(-1) as! Table
        }

        internal func popError() -> String {
            let err = popValue(-1) as! String
            return err
        }

        fileprivate func createUserdata<T: LuaCustomTypeInstance>(_ o: T) -> Userdata {
            let userdata = lua_newuserdata(state, MemoryLayout<T>.size) // this both pushes ptr onto stack and returns it

            let ptr = userdata!.bindMemory(to: T.self, capacity: 1)
            ptr.initialize(to: o) // creates a new legit reference to o

            luaL_setmetatable(state, T.luaTypeName().cString(using: .utf8)) // this requires ptr to be on the stack
            return popValue(-1) as! Userdata // this pops ptr off stack
        }

        fileprivate func eval(function f: Function, args: [LuaValueRepresentable]) throws -> [LuaValueRepresentable] {
            try f.call(args)
        }

        internal func createFunction(_ fn: @escaping ([LuaValueRepresentable]) throws -> [LuaValueRepresentable]) -> Function {
            let f: @convention(block) (OpaquePointer) -> Int32 = { [weak self] _ in
                guard let vm = self else { return 0 }

                // build args list
                var args = [LuaValueRepresentable]()
                for _ in 0 ..< vm.stackSize() {
                    guard let arg = vm.popValue(1) else { break }
                    args.append(arg)
                }

                // call fn
                do {
                    let values = try fn(args)
                    values.forEach { $0.push(vm) }
                    return Int32(values.count)
                } catch {
                    let e = (error as? LocalizedError)?.errorDescription ?? "Swift Error \(error)"
                    e.push(vm)
                    return lua_error(vm.state)
                }
            }
            let block: AnyObject = unsafeBitCast(f, to: AnyObject.self)
            let imp = imp_implementationWithBlock(block)

            let fp = unsafeBitCast(imp, to: lua_CFunction.self)
            lua_pushcclosure(state, fp, 0)
            return popValue(-1) as! Function
        }

        fileprivate func argError(_ expectedType: String, at argPosition: Int) {
            luaL_argerror(state, Int32(argPosition), expectedType.cString(using: .utf8))
        }

        fileprivate func createCustomType<T>(_ setup: (CustomType<T>) -> Void) -> CustomType<T> {
            lua_createtable(state, 0, 0)
            let lib = CustomType<T>(self)
            pop()

            setup(lib)

            registry[T.luaTypeName()] = lib
            lib.becomeMetatableFor(lib)
            lib["__index"] = lib
            lib["__name"] = T.luaTypeName()

            let gc = lib.gc
            lib["__gc"] = createFunction { [weak self] args in
                _ = self
                let ud = try Userdata.unwrap(args[0])
                if let gc {
                    gc(ud.toCustomType())
                }
                (ud.userdataPointer() as UnsafeMutablePointer<T>).deinitialize(count: 1)
                return []
            }

            if let eq = lib.eq {
                lib["__eq"] = createFunction { [weak self] args in
                    guard let self else { return [false] }
                    let a: T = try Userdata.unwrap(self, args[0]).toCustomType()
                    let b: T = try Userdata.unwrap(self, args[1]).toCustomType()
                    return [eq(a, b)]
                }
            }
            return lib
        }

        // stack

        internal func moveToStackTop(_ position: Int) {
            var position = position
            if position == -1 || position == stackSize() { return }
            position = absolutePosition(position)
            pushFromStack(position)
            remove(position)
        }

        internal func ref(_ position: Int) -> Int { return Int(luaL_ref(state, Int32(position))) }
        internal func unref(_ table: Int, _ position: Int) { luaL_unref(state, Int32(table), Int32(position)) }
        internal func absolutePosition(_ position: Int) -> Int { return Int(lua_absindex(state, Int32(position))) }
        internal func rawGet(tablePosition: Int, index: Int) { lua_rawgeti(state, Int32(tablePosition), lua_Integer(index)) }

        internal func pushFromStack(_ position: Int) {
            lua_pushvalue(state, Int32(position))
        }

        internal func pop(_ n: Int = 1) {
            lua_settop(state, -Int32(n)-1)
        }

        internal func rotate(_ position: Int, n: Int) {
            lua_rotate(state, Int32(position), Int32(n))
        }

        internal func remove(_ position: Int) {
            rotate(position, n: -1)
            pop(1)
        }

        internal func stackSize() -> Int {
            return Int(lua_gettop(state))
        }

    }
}
