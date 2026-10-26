import Foundation

/// Decides a kind from names alone. A directory's kind is inherited by everything
/// inside it unless something deeper overrides it, so a PNG inside an app bundle
/// counts as the app, not as a photo.
enum Classifier {
    /// Paths relative to the Data volume root that mean something on their own.
    static let topLevel: [String: Kind] = [
        "Applications": .apps,
        "opt": .developer,
        "usr/local": .developer,
        "Library/Developer": .developer,
        "Library/Caches": .caches,
        "Library/Logs": .caches,
        "System/Library/Caches": .caches,
        "private/var/folders": .caches,
        "private/var/log": .caches,
        "private/var/vm": .other,
    ]

    static let byName: [String: Kind] = [
        "Applications": .apps,
        "node_modules": .developer, ".git": .developer, "DerivedData": .developer,
        ".cargo": .developer, ".rustup": .developer, ".npm": .developer, ".nvm": .developer,
        ".gradle": .developer, ".m2": .developer, ".pyenv": .developer, ".bun": .developer,
        ".deno": .developer, ".docker": .developer, ".orbstack": .developer, "Cellar": .developer,
        "homebrew": .developer, "CoreSimulator": .developer, ".venv": .developer,
        "site-packages": .developer, ".pub-cache": .developer, ".gem": .developer,
        ".rbenv": .developer, ".pnpm-store": .developer, ".yarn": .developer,
        ".terraform": .developer, ".swiftpm": .developer, "com.docker.docker": .developer,
        "HUAQ24HBR6.dev.orbstack": .developer, "UTM": .developer,
        "Caches": .caches, "Cache": .caches, ".cache": .caches, "Logs": .caches,
        "DiagnosticReports": .caches, "Code Cache": .caches, "GPUCache": .caches,
        "CachedData": .caches, "CacheStorage": .caches, "ShaderCache": .caches,
        "Application Support": .appData, "Containers": .appData, "Group Containers": .appData,
        "Mail": .appData, "Messages": .appData, "Preferences": .appData,
        "Saved Application State": .appData, "WebKit": .appData, "HTTPStorages": .appData,
        "Mobile Documents": .documents,
    ]

    static let mediaPackages = [".photoslibrary", ".musiclibrary", ".imovielibrary", ".fcpbundle",
                                ".tvlibrary", ".logicx", ".band", ".lrlibrary", ".aplibrary"]

    /// Directories macOS treats as a single document or app. Silt never offers to delete
    /// anything inside one, because pulling a file out of a bundle breaks the bundle.
    static let packageSuffixes = [".app", ".framework", ".bundle", ".plugin", ".kext", ".appex", ".xpc",
                                  ".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary",
                                  ".imovielibrary", ".fcpbundle", ".logicx", ".band", ".sparsebundle",
                                  ".xcarchive", ".xcodeproj", ".xcworkspace", ".playground", ".pkg",
                                  ".mpkg", ".rtfd", ".pages", ".numbers", ".key", ".dsym", ".lrlibrary",
                                  ".aplibrary", ".utm", ".pvm", ".vmwarevm", ".lrcat-data"]

    static func isPackage(_ name: String) -> Bool {
        guard name.contains(".") else { return false }
        let lower = name.lowercased()
        return packageSuffixes.contains { lower.hasSuffix($0) }
    }

    /// Cache folders are often named after a bundle ID (`~/Library/Caches/com.example.app`), so a
    /// code-bundle suffix alone isn't proof. A real bundle has its standard layout inside.
    static let codeBundles = [".app", ".framework", ".bundle", ".plugin", ".kext", ".appex", ".xpc"]

    static func isCodeBundleName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return codeBundles.contains { lower.hasSuffix($0) }
    }

    static func isRealBundle(name: String, at path: String) -> Bool {
        guard isCodeBundleName(name) else { return true }
        return ["Contents", "Info.plist", "Versions", "Resources"].contains {
            FileManager.default.fileExists(atPath: path + "/" + $0)
        }
    }

    static func context(forDirectory name: String, parentName: String, parentContext: Kind?, relPath: String?,
                        isBundle: Bool) -> Kind? {
        if let rel = relPath, let k = topLevel[rel] { return k }
        if isBundle && name.hasSuffix(".app") { return .apps }
        if let k = byName[name] { return k }
        if name == "Developer" && parentName == "Library" { return .developer }
        if name == "Library" && parentContext == nil { return .appData }
        if name.contains(".") {
            let lower = name.lowercased()
            if mediaPackages.contains(where: { lower.hasSuffix($0) }) { return .media }
        }
        return parentContext
    }

    static let byExtension: [String: Kind] = {
        var m: [String: Kind] = [:]
        for e in ["jpg", "jpeg", "png", "heic", "heif", "gif", "tif", "tiff", "bmp", "webp", "raw", "cr2", "cr3",
                  "nef", "arw", "dng", "orf", "rw2", "psd", "mov", "mp4", "m4v", "avi", "mkv", "webm", "mts",
                  "m2ts", "3gp", "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "caf", "mid"] {
            m[e] = .media
        }
        for e in ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "key", "pages", "numbers", "txt", "md",
                  "rtf", "csv", "tsv", "epub", "odt", "ods", "odp", "sketch", "fig", "ai", "indd"] {
            m[e] = .documents
        }
        for e in ["zip", "dmg", "pkg", "mpkg", "iso", "xip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar",
                  "zst", "ipsw", "sparseimage", "cdr"] {
            m[e] = .archives
        }
        for e in ["swift", "rs", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "pyc", "go", "c", "h", "cpp",
                  "hpp", "m", "mm", "java", "kt", "class", "jar", "o", "a", "dylib", "so", "rlib", "rmeta",
                  "wasm", "map", "pdb", "node", "vmdk", "qcow2", "vdi", "hdd", "raw.img", "lock"] {
            m[e] = .developer
        }
        return m
    }()

    static func kind(ofFile name: String) -> Kind? {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return nil }
        let ext = name[name.index(after: dot)...].lowercased()
        return byExtension[ext]
    }

    static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "ipsw"]

    static func isInstaller(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return installerExtensions.contains(name[name.index(after: dot)...].lowercased())
    }
}
