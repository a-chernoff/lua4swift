#if canImport(Cocoa)
import Cocoa
#endif
import XCTest

import Foundation
import CLua
@testable import lua4swift

class Lua_Tests: XCTestCase {
    func testStringFormat() throws {
        let vm = Lua.VirtualMachine(openLibs: true)
        let result = try vm.eval("""
            return string.format("%d", 1.5)
            """)
        let formatted = try XCTUnwrap(result[0] as? String)
        XCTAssertEqual(formatted, "1")
    }

    func testPatchedGsub() throws {
        let vm = Lua.VirtualMachine()
        let result = try vm.eval("""
            s = string.gsub("Lua is cute", "cute", "great")
            return s
            """)

        XCTAssertEqual(result.count, 1)
        let sub = try XCTUnwrap(result[0] as? String)
        XCTAssertEqual(sub, "Lua is great")
    }

    func testDoFileWithBundlePrefix() throws {
        let vm = Lua.VirtualMachine()
        try vm.setFilePrefix(Bundle.module.resourceURL!)
        let result = try vm.eval("""
            return dofile("test.lua")
            """)

        XCTAssertEqual(result.count, 1)
        let table = try XCTUnwrap(result[0] as? Lua.Table)
        XCTAssertNotNil(table["writeobj"])
    }

    func testEvalURL() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "lua"))
        let vm = Lua.VirtualMachine()
        _ = try vm.eval(url)
    }

    func testEvalURLWithPrefix() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "lua"))
        let vm = Lua.VirtualMachine()
        try vm.setFilePrefix(Bundle.module.resourceURL!)
        _ = try vm.eval(url)
    }

    func testLoadWriteModule() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "lua"))
        let vm = Lua.VirtualMachine()
        try vm.loadModule(name: "write", url: url)
        _ = try vm.eval("""
            local write = require 'write'
            write.writeobj(_G)
            """)
    }

    func testLoadAsdfModule() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "test", withExtension: "lua"))
        let vm = Lua.VirtualMachine()
        try vm.loadModule(name: "asdf", url: url)
        _ = try vm.eval("""
            local asdf = require 'asdf'
            asdf.writeobj(_G)
            """)
    }

    func testFundamentals() {
        let vm = Lua.VirtualMachine()
        let table = vm.createTable()
        table[3] = "foo"
        XCTAssert(table[3] is String)
        XCTAssertEqual(table[3] as! String, "foo")
    }

    func testStringX() {
        let vm = Lua.VirtualMachine()

        let stringxLib = vm.createTable()

        stringxLib["split"] = vm.createFunction { [unowned vm] args in
            let subject = try String.unwrap(vm.state, args[0])
            let separator = try String.unwrap(vm.state, args[1])
            let fragments = subject.components(separatedBy: separator)

            let results = vm.createTable()
            for (i, fragment) in fragments.enumerated() {
                results[i+1] = fragment
            }
            return results
        }

        vm.globals["stringx"] = stringxLib

        do {
            let values = try vm.eval("return stringx.split('hello world', ' ')")
            XCTAssertEqual(values.count, 1)
            XCTAssert(values[0] is Lua.Table)
            let array: [String] = (values[0] as! Lua.Table).asArray()!
            XCTAssertEqual(array, ["hello", "world"])
        } catch {
            XCTFail(error.localizedDescription)
        }
    }

    func testCustomType() {
        class Note: LuaCustomTypeInstance {
            var name = ""
            static func luaTypeName() -> String {
                return "note"
            }
        }

        let vm = Lua.VirtualMachine()

        let noteLib: Lua.CustomType<Note> = vm.createCustomType { type in
            type["setName"] = type.createMethod { [unowned vm] (self, args) -> Void in
                let name = try String.unwrap(vm.state, args[0])
                self.name = name
            }
            type["getName"] = type.createMethod { (self: Note, _) in
                self.name
            }
        }

        noteLib["new"] = vm.createFunction { [unowned vm] args in
            let name = try String.unwrap(vm.state, args[0])
            let note = Note()
            note.name = name
            return vm.createUserdata(note)
        }

        // setup the note class
        vm.globals["note"] = noteLib

        _ = try! vm.eval("myNote = note.new('a custom note')")
        XCTAssert(vm.env?["myNote"] is Lua.Userdata)

        // extract the note
        // and see if the name is the same

        let myNote: Note = (vm.env?["myNote"] as! Lua.Userdata).toCustomType()
        XCTAssert(myNote.name == "a custom note")

        // This is just to highlight changes in Swift
        // will get reflected in Lua as well
        // TODO: redirect output from Lua to check if both
        // are equal

        myNote.name = "now from XCTest"
        _ = try! vm.eval("print(myNote:getName())")

        // further checks to change name in Lua
        // and see change reflected in the Swift object

        _ = try! vm.eval("myNote:setName('even')")
        XCTAssert(myNote.name == "even")

        _ = try! vm.eval("myNote:setName('odd')")
        XCTAssert(myNote.name == "odd")
    }

    func testLifetime() throws {
        class LT: LuaCustomTypeInstance {
            nonisolated(unsafe) static var deinitCount = 0

            static func luaTypeName() -> String {
                return "LifeThreateningLifestyles"
            }

            deinit {
                Self.deinitCount += 1
            }
        }

        try {
            let vm = Lua.VirtualMachine()
            let lib: Lua.CustomType<LT> = vm.createCustomType { _ in }

            lib["new"] = vm.createFunction { [unowned vm] _ in
                _ = vm
                let l = LT()
                return vm.createUserdata(l)
            }

            vm.globals["LT"] = lib

            _ = try vm.eval("""
                local l = LT.new()
                global = LT.new()
            """)
        }()

        XCTAssertEqual(LT.deinitCount, 2)
    }

    func testSetEnv() throws {
        class T: LuaCustomTypeInstance {
            static func luaTypeName() -> String {
                return "T"
            }
        }

        let vm = Lua.VirtualMachine()
        let lib: Lua.CustomType<T> = vm.createCustomType { t in
            t["callback"] = t.createMethod { (self, args) -> Void in
                let fx = try Lua.Function.unwrap(args[0])
                _ = try fx.call([])
            }
        }

        lib["new"] = vm.createFunction { [unowned vm] _ in
            _ = vm
            let l = T()
            return vm.createUserdata(l)
        }

        vm.globals["T"] = lib

        _ = try vm.eval("""
            local l = T.new()
            l:callback(function ()
            end)
        """)
    }
}
