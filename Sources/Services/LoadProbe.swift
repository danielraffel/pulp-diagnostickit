import Foundation

/// Loads a plug-in's binary the way a host does and asks it what it contains.
/// Runs in a CHILD process (`--load-probe <kind> <bundle>`), so a plug-in that
/// crashes on load takes down the probe, not the diagnostics app; the parent
/// reads the exit status and the lines printed here.
///
/// It proves the binary loads on this Mac (dyld, architecture, signature and
/// library validation all happen in `dlopen`) and that the format's entry
/// point answers. It does not process audio or open an editor.
enum LoadProbe {
    static func run(kind: String, bundlePath: String) -> Int32 {
        guard let bundle = Bundle(path: bundlePath), let exe = bundle.executablePath else {
            print("PROBE_FAIL no executable in \(bundlePath)")
            return 2
        }
        guard let handle = dlopen(exe, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            print("PROBE_FAIL dlopen: \(reason)")
            return 3
        }
        print("PROBE dlopen ok")
        switch kind {
        case "clap": return probeClap(handle, bundlePath: bundlePath)
        case "vst3": return probeVst3(handle, bundlePath: bundlePath)
        default:
            print("PROBE_FAIL unknown kind \(kind)")
            return 2
        }
    }

    // clap_plugin_entry: clap_version_t (3 x uint32, padded to 16), then the
    // init / deinit / get_factory function pointers.
    private typealias ClapInit = @convention(c) (UnsafePointer<CChar>) -> Bool
    private typealias ClapDeinit = @convention(c) () -> Void
    private typealias ClapGetFactory = @convention(c) (UnsafePointer<CChar>) -> UnsafeRawPointer?
    private typealias ClapCount = @convention(c) (UnsafeRawPointer) -> UInt32
    private typealias ClapDescriptor = @convention(c) (UnsafeRawPointer, UInt32) -> UnsafeRawPointer?

    private static func probeClap(_ handle: UnsafeMutableRawPointer, bundlePath: String) -> Int32 {
        guard let entry = dlsym(handle, "clap_entry") else {
            print("PROBE_FAIL no clap_entry symbol")
            return 4
        }
        let base = UnsafeRawPointer(entry)
        print("PROBE clap_version \(base.load(as: UInt32.self)).\(base.load(fromByteOffset: 4, as: UInt32.self)).\(base.load(fromByteOffset: 8, as: UInt32.self))")
        let initFn = unsafeBitCast(base.load(fromByteOffset: 16, as: UnsafeRawPointer.self), to: ClapInit.self)
        let deinitFn = unsafeBitCast(base.load(fromByteOffset: 24, as: UnsafeRawPointer.self), to: ClapDeinit.self)
        let factoryFn = unsafeBitCast(base.load(fromByteOffset: 32, as: UnsafeRawPointer.self), to: ClapGetFactory.self)
        guard initFn(bundlePath) else {
            print("PROBE_FAIL clap_entry.init returned false")
            return 5
        }
        defer { deinitFn() }
        guard let factory = factoryFn("clap.plugin-factory") else {
            print("PROBE_FAIL no clap.plugin-factory")
            return 6
        }
        let count = unsafeBitCast(factory.load(as: UnsafeRawPointer.self), to: ClapCount.self)(factory)
        let describe = unsafeBitCast(factory.load(fromByteOffset: 8, as: UnsafeRawPointer.self), to: ClapDescriptor.self)
        print("PROBE plugins \(count)")
        for i in 0..<count {
            guard let d = describe(factory, i) else { continue }
            func str(_ offset: Int) -> String {
                guard let p = d.load(fromByteOffset: offset, as: UnsafePointer<CChar>?.self) else { return "" }
                return String(cString: p)
            }
            print("PROBE plugin id=\(str(16)) name=\(str(24)) vendor=\(str(32)) version=\(str(64))")
        }
        return count > 0 ? 0 : 7
    }

    // VST3 on macOS: bundleEntry(CFBundleRef) before GetPluginFactory(), and
    // bundleExit() after. IPluginFactory's vtable is FUnknown's three methods
    // followed by getFactoryInfo, countClasses, getClassInfo.
    private typealias BundleEntry = @convention(c) (CFBundle) -> Bool
    private typealias BundleExit = @convention(c) () -> Bool
    private typealias GetFactory = @convention(c) () -> UnsafeMutableRawPointer?
    private typealias Release = @convention(c) (UnsafeMutableRawPointer) -> UInt32
    private typealias FactoryInfo = @convention(c) (UnsafeMutableRawPointer, UnsafeMutableRawPointer) -> Int32
    private typealias CountClasses = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias ClassInfo = @convention(c) (UnsafeMutableRawPointer, Int32, UnsafeMutableRawPointer) -> Int32

    private static func probeVst3(_ handle: UnsafeMutableRawPointer, bundlePath: String) -> Int32 {
        if let entry = dlsym(handle, "bundleEntry"),
           let cfBundle = CFBundleCreate(nil, URL(fileURLWithPath: bundlePath) as CFURL) {
            guard unsafeBitCast(entry, to: BundleEntry.self)(cfBundle) else {
                print("PROBE_FAIL bundleEntry returned false")
                return 5
            }
        }
        defer {
            if let exit = dlsym(handle, "bundleExit") { _ = unsafeBitCast(exit, to: BundleExit.self)() }
        }
        guard let getFactory = dlsym(handle, "GetPluginFactory") else {
            print("PROBE_FAIL no GetPluginFactory symbol")
            return 4
        }
        guard let factory = unsafeBitCast(getFactory, to: GetFactory.self)() else {
            print("PROBE_FAIL GetPluginFactory returned null")
            return 6
        }
        let vtable = factory.load(as: UnsafeRawPointer.self)
        func method<T>(_ index: Int, _ type: T.Type) -> T {
            unsafeBitCast(vtable.load(fromByteOffset: index * 8, as: UnsafeRawPointer.self), to: type)
        }
        defer { _ = method(2, Release.self)(factory) }

        // PFactoryInfo: vendor[64], url[256], email[128], flags.
        let info = UnsafeMutableRawPointer.allocate(byteCount: 64 + 256 + 128 + 8, alignment: 8)
        defer { info.deallocate() }
        if method(3, FactoryInfo.self)(factory, info) == 0 {
            print("PROBE vendor \(String(cString: info.assumingMemoryBound(to: CChar.self)))")
        }
        let count = method(4, CountClasses.self)(factory)
        print("PROBE classes \(count)")
        // PClassInfo: cid[16], cardinality, category[32], name[64].
        let cls = UnsafeMutableRawPointer.allocate(byteCount: 16 + 4 + 32 + 64, alignment: 8)
        defer { cls.deallocate() }
        for i in 0..<max(0, count) where method(5, ClassInfo.self)(factory, i, cls) == 0 {
            let category = String(cString: (cls + 20).assumingMemoryBound(to: CChar.self))
            let name = String(cString: (cls + 52).assumingMemoryBound(to: CChar.self))
            print("PROBE class category=\(category) name=\(name)")
        }
        return count > 0 ? 0 : 7
    }
}
