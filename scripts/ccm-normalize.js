// CCM normalizer for claude-code-router.
// Claude Code sends content as ARRAYS of blocks and adds `cache_control` markers for prompt
// caching. Strict OpenAI-compatible providers (Mistral, etc.) reject both: they want the
// system/user/assistant text content as a plain STRING and forbid the `cache_control` field
// (HTTP 422: "Input should be a valid string" / "Extra inputs are not permitted").
// This transformer (a) removes every `cache_control` anywhere in the request and (b) flattens
// any pure-text content array to a single string, while leaving tool/image blocks structured
// so tool calling still works.
class CcmNormalize {
  constructor(options) { this.name = "ccmnormalize"; this.options = options || {}; }

  _stripCache(o) {
    if (Array.isArray(o)) { for (const x of o) this._stripCache(x); return; }
    if (o && typeof o === "object") {
      if ("cache_control" in o) { try { delete o.cache_control; } catch (e) {} }
      for (const k of Object.keys(o)) this._stripCache(o[k]);
    }
  }
  _isAllText(a) {
    return Array.isArray(a) && a.length > 0 && a.every((b) =>
      typeof b === "string" ||
      (b && typeof b === "object" && (b.type === "text" || (typeof b.text === "string" && b.type == null)) &&
       b.type !== "image" && b.type !== "image_url" && b.type !== "tool_use" && b.type !== "tool_result")
    );
  }
  _join(a) {
    return a.map((b) => (typeof b === "string" ? b : (b && typeof b.text === "string" ? b.text : "")))
            .filter((s) => s && s.length).join("\n\n");
  }
  async transformRequestIn(request) {
    try {
      this._stripCache(request);
      if (Array.isArray(request.system)) request.system = this._join(request.system);
      if (Array.isArray(request.messages)) {
        for (const m of request.messages) {
          if (m && Array.isArray(m.content) && this._isAllText(m.content)) m.content = this._join(m.content);
        }
      }
    } catch (e) {}
    return request;
  }
}
module.exports = CcmNormalize;
