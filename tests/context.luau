local context = ...
context.setup("editor")
assert(context.editorId() == "editor")
local restore = context.beginTest("test")
assert(context.testId() == "test" and attrs._MCPTestEditor == "editor")
-- Runtime copies have their own plugin ID, but inherit the editor metadata.
edit = false; context.setup("runtime")
assert(context.editorId() == "editor" and context.testId() == "test")
edit = true; restore()
assert(attrs._MCPTestEditor == nil and attrs._MCPTestId == nil and attrs.user == "preserved")
context.setup("editor")
context.beginTest("second"); context.cleanup()
assert(context.testId() == nil)
-- Do not erase metadata owned by a subsequent test during delayed cleanup.
restore = context.beginTest("third")
attrs._MCPTestId = "newer"
restore(); assert(attrs._MCPTestId == "newer")
print("context: origin metadata, restoration and ownership guards pass")
