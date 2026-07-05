/// A Quill-style delta operation, as produced by `YText.toDelta` and text
/// observers, and consumed when materializing to `content` / `format_data`.
public enum Delta: Sendable, Hashable {
    /// Insert content — text is `.string`, embeds are `.object` — with optional
    /// formatting attributes.
    case insert(YValue, attributes: Attributes?)
    /// Keep `length` UTF-16 code units, optionally applying formatting.
    case retain(Int, attributes: Attributes?)
    /// Delete `length` UTF-16 code units.
    case delete(Int)
}
