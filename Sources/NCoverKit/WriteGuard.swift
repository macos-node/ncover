import Foundation

public enum WriteGuardError: LocalizedError, Equatable {
    case outputIsSource
    case outputInsideSource
    case overwriteNotPNG(String)

    public var errorDescription: String? {
        switch self {
        case .outputIsSource:
            return "The output folder is the source folder. Batch never writes over your originals."
        case .outputInsideSource:
            return "The output folder is inside the source folder. The next run would batch its own output."
        case .overwriteNotPNG(let ext):
            return "Overwrite replaces a PNG in place. This source is .\(ext), and saving it as PNG under its own name would silently change the format."
        }
    }
}

/// Refuse a source/output pairing that would eat itself.
///
/// Inherited verbatim from the GTK app, and non-negotiable: the output folder
/// is a user-typed path and the originals are the irreplaceable thing. Never
/// writes into the source tree — not as an option, not with a confirmation. Also
/// refuses output nested INSIDE the source, which would not overwrite anything
/// but would make the next run batch its own output.
public func guardBatch(source: URL, output: URL) throws {
    let real = { (u: URL) -> URL in
        URL(fileURLWithPath: (u.path as NSString).standardizingPath).resolvingSymlinksInPath()
    }
    let s = real(source), o = real(output)
    if o.path == s.path { throw WriteGuardError.outputIsSource }

    let sParts = s.pathComponents
    let oParts = o.pathComponents
    if oParts.count > sParts.count, Array(oParts.prefix(sParts.count)) == sParts {
        throw WriteGuardError.outputInsideSource
    }
}

/// Overwrite may only ever replace a PNG.
///
/// We save PNG, so overwriting anything else would silently change the format —
/// and for a JPEG, quietly re-encode it as PNG under the same name.
public func guardOverwrite(source: URL) throws {
    let ext = source.pathExtension.lowercased()
    guard ext == "png" else { throw WriteGuardError.overwriteNotPNG(ext.isEmpty ? "(none)" : ext) }
}

/// What we will open. Anything else is simply not an image.
public let IMAGE_EXTS = ["png", "jpg", "jpeg", "webp", "svg"]
