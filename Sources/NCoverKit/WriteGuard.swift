import Foundation

public enum WriteGuardError: LocalizedError, Equatable {
    case outputIsSource
    case outputInsideSource
    case sourceInsideOutput
    /// A format we do not write at all.
    case overwriteUnsupported(String)
    /// A JPEG asked for, and the result is not opaque.
    case overwriteJPEGHasAlpha

    public var errorDescription: String? {
        switch self {
        case .outputIsSource:
            return "The output folder is the source folder. Batch never writes over your originals."
        case .outputInsideSource:
            return "The output folder is inside the source folder. The next run would batch its own output."
        case .sourceInsideOutput:
            return "The source folder is inside the output folder. Choose an output folder beside it, not above it."
        case .overwriteUnsupported(let ext):
            return "Overwrite keeps the file's own format, and this app does not write .\(ext) — it would have to become a PNG or a JPEG under a name that says otherwise."
        case .overwriteJPEGHasAlpha:
            return "This result has transparent areas and a JPEG has no alpha channel, so Overwrite would store them as black. Turn the disc off, put a background behind it, or save it as a new PNG."
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
    // And the other way round. Nothing of the user's would be overwritten, but
    // a run would write its output over the folder the originals sit in and
    // the next one would read it back — the same compounding, upside down.
    if sParts.count > oParts.count, Array(sParts.prefix(oParts.count)) == oParts {
        throw WriteGuardError.sourceInsideOutput
    }
}

/// Overwrite replaces a file in **its own format** — and only a format this
/// app writes, with something that format can actually hold.
///
/// It used to be PNG or nothing, which was right while PNG was all we wrote:
/// re-encoding a JPEG as PNG under its own name changes the file's kind behind
/// the user's back. Now that the write layer encodes both, the rule that
/// matters is the alpha one. A JPEG has no alpha channel, and the bytes left
/// behind when the channel is dropped are **black**, not white — so a masked
/// render written over a JPEG cover would come back with black corners and no
/// error. That is refused here rather than flattened onto a colour nobody
/// chose. (Batch's keep-format jobs answer the same question with
/// `JPEGAlpha.discard`, because a JPEG source has no transparency to lose;
/// the two answers are deliberate and live at their own call sites.)
///
/// `resultIsOpaque` is the render that is about to be written, not the source.
/// It is required rather than defaulted: a caller that has not looked is
/// exactly the caller this guard exists for.
public func guardOverwrite(source: URL, resultIsOpaque: Bool) throws {
    let ext = source.pathExtension.lowercased()
    guard let format = ImageFormat.of(source) else {
        throw WriteGuardError.overwriteUnsupported(ext.isEmpty ? "(none)" : ext)
    }
    if format == .jpeg, !resultIsOpaque { throw WriteGuardError.overwriteJPEGHasAlpha }
}

/// What we will open. Anything else is simply not an image.
public let IMAGE_EXTS = ["png", "jpg", "jpeg", "webp", "svg"]
