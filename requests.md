IMPORTANT: This file is just for human-typed bugfix/feature requests. AGENTS
SHOULD NEVER MODIFY THIS

AGENTS ARE ONLY ALLOWED TO "TICK OFF" TASKS WHEN COMPLETE

## Bugs

- [ ] Seems like despite recent fixes to optimize draw throughput, we still get
  stuck sometimes in a strange state where there's a lot of draws (i.e. after
  the water moves a while in `weave`, the draws don't settle down. If I close
  and reopen the panel the draws stop.

  Even after resize (which resets the water thingy) the draws keep going
  (noticed due to ssh+tmux cursor flicker). The cursor flickers to positions
  around the transcript buffer, so seems like it's trying to redraw the
  trasncript?

  Do scroll calls trigger buffer redraw even if the topline doesn't change?

- [ ] weave: Transcript gets quite slow to resize, etc as it grows. We have
  underestimated the cost of re-rendering the full transcript in the longer
  cases. I cannot overstate how large these sessions get; 50MB is not uncommon
  for multi-day sessions.

- [ ] weave:Long task lists overflow container. Maybe need to be nested into a
  `render = "focus"` subcontainer.

## Features

- [ ] weave: Latex math support in markdown widget (need some way of rendering
  latex math -> ascii/unicode)

- [ ] weave: Usage metadata in sidebar

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

- [ ] weave: Kiro session support. See how our vendored agentic in
  `nix-dotfiles` handles it, since kiro does not implement ACP session stuff.

- [ ] weave: Experiment with replacing the Hooke's law water sim with a
  SWE-based sim (shallow water equations).

- [ ] fibrous-docs: Add separate page/tab/TBD with documentation for each
  builtin component type (including all supported props).

  Also document mount apis and such; so just full documentation of the library
  essentially.

- [ ] Interacting with an unfocused buffer

  - [ ] `dd` over an unfocused text edit buffer should focus it and delete the
    line. Same for things like `cb`, `ce`, etc.

- [ ] <Esc> from normal mode in a focused subcontainer unfocuses it and moves
  focus to the parent.

## Spikes

- [ ] weave: Using a live session (here you can use opencode for example), check
  what kind of requests we aren't currently handling. This will help us identify
  gaps in our ACP client
