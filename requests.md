IMPORTANT: This file is just for human-typed bugfix/feature requests. AGENTS
SHOULD NEVER MODIFY THIS

AGENTS ARE ONLY ALLOWED TO "TICK OFF" TASKS WHEN COMPLETE

## Bugs

- [x] Seems like despite recent fixes to optimize draw throughput, we still get
  stuck sometimes in a strange state where there's a lot of draws (i.e. after
  the water moves a while in `weave`, the draws don't settle down. If I close
  and reopen the panel the draws stop.

  Even after resize (which resets the water thingy) the draws keep going
  (noticed due to ssh+tmux cursor flicker). The cursor flickers to positions
  around the transcript buffer, so seems like it's trying to redraw the
  trasncript?

  Do scroll calls trigger buffer redraw even if the topline doesn't change?

- [x] weave: Transcript gets quite slow to resize, etc as it grows. We have
  underestimated the cost of re-rendering the full transcript in the longer
  cases. I cannot overstate how large these sessions get; 50MB is not uncommon
  for multi-day sessions.

- [x] weave: Resizing the window horizontally, or toggling thinkin in a very
  long transcript sends your cursor haywire, and we lose our position in the
  trascript; this is very disorienting. I would rather the transcript cursor
  stays pinned.

- [x] fibrous+weave: Hovering a tool call on the transcript while the transcript
  is unfocused causes a flurry of redraws (cursor flickering on ssh+tmux)

- [x] fibrous/weave?: Water is causing flicker-frenzy again (too many redraws).
  Strangely now this only happens when there's no subcontainer focused (i.e. the
  cursor focus is on the root float).

  - [x] WHY DID OUR BENCHES AND TESTS NOT CATCH THIS REGRESSION?

- [ ] fibrous+weave: If transcript is not focused, there's no anchoring. I think
  we should still anchor buffers that aren't focused.

- [ ] weave: We should make it clear when the turn is ended (maybe different
  color in water?); sometimes it's not clear if we're waiting for the agent's
  tool call or we have the mike.

- [ ] weave: `allow` permission option should always be on the first slot if
  it's present. Sometimes `claude-agent-acp` sends it second, so muscle memory
  of clicking `;;1` to approve betrays me.

- [ ] fibrous+weave: In the parent buffer in weave, moving the cursor all the
  way to the right (`$`) in visual mode scrolls the window one cell to the
  right. This is because the newline char at the end of a line is selectable in
  visual mode, so if the line already reaches the end of the window, the newline
  will lie outside the window and cause a scroll.

  - Not sure what the best solution is. Perhaps if `scroll_x` is disabled in a
    buffer, we should limit rendering to one cell before the edge of the window?

- [ ] weave:Long task lists overflow container. Maybe need to be nested into a
  `render = "focus"` subcontainer.

## Features

- [ ] weave: Want timestamps + total duration of generation/execution (when
  relevant) after prompts, tool calls, thinking blocks and generation blocks. In
  tool calls you can include them in the toggleable metadata.

- [ ] weave: Latex math support in markdown widget (need some way of rendering
  latex math -> ascii/unicode)

- [x] weave: Usage metadata in sidebar

- [ ] weave: Session details window. Activating the session metadata sidebar
  section should open a modal with full session details/metadata. From that
  modal we should be able to change what fields can be changed (e.g. model,
  mode, thinking effort, etc).

  - [ ] fibrous: dropdown component. IMPORTANT: Needs discussion with user!

- [ ] weave: ACP terminal stuff. IMPORTANT: Needs discussion with user!

- [ ] weave: Configurable keybinds and documented API surface

- [ ] fibrous: entering visual mode when hovering over a subbuffer should focus
  it.

- [ ] weave: Better prompt queue and prompt history handling. IMPORTANT: Needs
  discussion with user!

- [x] weave: Kiro session support. See how our vendored agentic in
  `nix-dotfiles` handles it, since kiro does not implement ACP session stuff.

- [ ] weave: Experiment with replacing the Hooke's law water sim with a
  SWE-based sim (shallow water equations).

- [x] fibrous-docs: Add separate page/tab/TBD with documentation for each
  builtin component type (including all supported props).

  Also document mount apis and such; so just full documentation of the library
  essentially.

- [ ] Interacting with an unfocused buffer

  - [ ] `dd` over an unfocused text edit buffer should focus it and delete the
    line. Same for things like `cb`, `ce`, etc.

- [ ] <Esc> from normal mode in a focused subcontainer unfocuses it and moves
  focus to the parent.

- [ ] fibrous-docs: "Architecture" section covering how fibrous works
  internally. Hierarchical explanation of each stage in rendering, where the
  boundaries are, and how they interact (which stage can trigger what, etc).
  Start with high level overview and then dive deep on each stage.

## Spikes

- [x] weave: Using a live session (here you can use opencode for example), check
  what kind of requests we aren't currently handling. This will help us identify
  gaps in our ACP client

- [ ] Possibility of moving fibrous-docs into a subflake under `docs`
  subdirectory within fibrous repo

- [ ] fibrous: What is the difference between a toplevel mount and a
  subcontainer? What code paths are shared? What code isn't but should be shared? What
  code cannot or should not be shared?
