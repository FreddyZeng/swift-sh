import Foundation

public class Script {
    let name: String
    let deps: [ImportSpecification]
    let script: String

    var path: Path {
        let root: Path
      #if os(macOS)
        root = Path.home/"Library/Developer/swift-sh.cache"
      #else
        if let path = ProcessInfo.processInfo.environment["XDG_CACHE_HOME"] {
            root = Path.root/path/"swift-sh"
        } else {
            root = Path.home/".cache/swift-sh"
        }
      #endif
        return root/name
    }

    public init(name: String, contents: [String], dependencies: [ImportSpecification]) {
        self.name = name
        script = contents.joined(separator: "\n")
        deps = dependencies
    }
    
    var shouldWriteFiles: Bool {
        return (try? String(contentsOf: path/"main.swift")) != script
    }
    
    func write() throws {
        //TODO we only support Swift 4.2 basically
        //TODO dependency module names can be anything so we need to parse Package.swifts for all deps to get module lists

        var importNames: String {
            return deps.map { """
                "\($0.importName)"
                """
            }.joined(separator: ", ")
        }

        try path.mkpath()
        try """
            // swift-tools-version:4.2

            import PackageDescription

            let pkg = Package(name: "\(name)")
            pkg.products = [
                .executable(name: "\(name)", targets: ["\(name)"])
            ]
            pkg.dependencies = [
                \(deps.map{ $0.packageLine }.joined(separator: ",\n    "))
            ]
            pkg.targets = [
                .target(name: "\(name)", dependencies: [
                    \(importNames)
                ], path: ".", sources: ["main.swift"])
            ]

            """.write(to: path/"Package.swift")

        try script.write(to: path/"main.swift")
    }

    public func run() throws -> Never {
        if shouldWriteFiles {
            // don‘t write `main.swift` if would be identical
            // ∵ prevents swift-build recognizing a null-build
            // ie. prevents unecessary rebuild of our script
            try write()
        }

        guard FileManager.default.changeCurrentDirectoryPath(path.string) else {
            throw Error.directoryChangeFailed(path)
        }

        // first arg has to be same as
        let swift = Library.swiftPath
        let cArgs = CStringArray([swift.string, "run"])
        guard execv(swift.string, cArgs.cArray) != -1 else {
            throw Error.swiftRun(swift: swift, errno: errno)
        }
        fatalError("Impossible if execv succeeded")
    }

    public enum Error: CommandLineError {
        case directoryChangeFailed(Path)
        case swiftRun(swift: Path, errno: Int32)

        public var stderrString: String {
            switch self {
            case .directoryChangeFailed(let path):
                return "could not chdir: \(path)"
            case .swiftRun(let swiftPath, let errno):
                if errno == 2 {
                    return "swift not found in PATH"
                } else {
                    return "swift run failed: \(Library.strerror(errno)): \(swiftPath)"
                }
            }
        }
    }
}

private  final class CStringArray {
    /// The null-terminated array of C string pointers.
    public let cArray: [UnsafeMutablePointer<Int8>?]

    /// Creates an instance from an array of strings.
    public init(_ array: [String]) {
        cArray = array.map({ $0.withCString({ strdup($0) }) }) + [nil]
    }

    deinit {
        for case let element? in cArray {
            free(element)
        }
    }
}

private extension ImportSpecification {
    var packageLine: String {
        var requirement: String {
            switch constraint {
            case .upToNextMajor(from: let v):
                return """
                    .upToNextMajor(from: "\(v)")
                    """
            case .exact(let v):
                return ".exactItem(Version(\(v.major),\(v.minor),\(v.patch)))"
            case .ref(let ref):
                return """
                    .revision("\(ref)")
                    """
            }
        }
        let urlstr: String
        if let url = URL(string: dependencyName), url.scheme != nil {
            urlstr = dependencyName
        } else {
            urlstr = "https://github.com/\(dependencyName).git"
        }
        return """
            .package(url: "\(urlstr)", \(requirement))
            """
    }
}

#if SWIFT_PACKAGE && DEBUG && !Xcode
private var swiftPath: Path {
    do {
        let yaml = Path.root.join(#file).parent.parent.parent.join(".build/debug.yaml")
        for line in try StreamReader(path: yaml) {
            guard let line = line.chuzzled() else { continue }
            if line.hasPrefix("executable:"), line.hasSuffix("swiftc\"") {
                let parts = line.split(separator: ":")
                guard parts.count == 2 else { continue }
                return Path.root.join(parts[1].trimmingCharacters(in: .init(charactersIn: " \n\""))).parent.join("swift")
            }
        }
        fatalError("Failed to find `swift`")
    } catch {
        fatalError("\(error)")
    }
}
#else
private var PATH: [Path] {
    guard let PATH = ProcessInfo.processInfo.environment["PATH"] else {
        return []
    }
    return PATH.split(separator: ":").map {
        if $0.first == "/" {
            return Path.root/$0
        } else {
            return Path.root/FileManager.default.currentDirectoryPath/$0
        }
    }
}

private var swiftPath: Path {
    for path in PATH where path.join("swift").isExecutable {
        return path/"swift"
    }

    // else use `which`
    let task = Process()
    task.launchPath = "/usr/bin/which"
    task.arguments = ["swift"]
    let str = (try? task.runSync())?.stdout.string?.chuzzled() ?? "/usr/bin/swift"
    return Path.root/str
}
#endif

extension String {
    func chuzzled() -> String? {
        let s = trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}
