-- The ui.markdown component: the stateful builtin that ties markdown source to
-- the shared renderer. It is exposed as `ui.markdown` via a lazy forwarder in
-- inline/components.lua, so importing the component surface never pulls the
-- parser onto the module graph.
--
-- Stateful because it CACHES the parsed AST on a ref keyed by the source string
-- (the AST is width-independent, so wrapping stays fibrous's job and a resize
-- never re-parses). While `live` (still streaming) it renders the raw text as a
-- plain paragraph and skips the parse entirely — parse on settle.
--
-- Props: text (markdown source), live (bool), on_link(url), highlight(text,
-- lang) to override the default treesitter code highlighter, plus the usual
-- layout/style props, which pass through to the outer col. Fenced code is
-- treesitter-highlighted by default (fibrous.doc.highlight), degrading to plain
-- where no parser is available.

local markdown = require("fibrous.markdown")
local render = require("fibrous.doc.render")
local ui = require("fibrous.inline.components")

-- Props threaded onto the widget's outer node: layout/style, plus the
-- node-level interaction props (on_key routes app keys to the whole block).
local PASS =
  { "style", "grow", "width", "height", "min_width", "max_width", "align_self", "gap", "on_key", "source_entry" }

return function(ctx, props)
  local text = props.text or ""

  local vnode
  if props.live then
    -- streaming: cheap plain render, no parse
    vnode = { comp = ui.paragraph, props = { text = text, source = props.source } }
  else
    local cache = ctx.use_ref()
    if not cache.current or cache.current.text ~= text or cache.current.mapped ~= (props.source ~= nil) then
      cache.current = { text = text, mapped = props.source ~= nil, doc = markdown.parse(text, { source = props.source ~= nil }) }
    end
    vnode = render.render(cache.current.doc, { on_link = props.on_link, highlight = props.highlight, source = props.source })
  end

  vnode.props = vnode.props or {}
  for _, k in ipairs(PASS) do
    if props[k] ~= nil then
      vnode.props[k] = props[k]
    end
  end
  return vnode
end
